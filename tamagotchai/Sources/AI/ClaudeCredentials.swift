import CryptoKit
import Foundation
import os
import Security

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "credentials"
)

/// OAuth credentials for the Anthropic API.
struct OAuthCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

/// File-based persistence for Claude OAuth credentials.
///
/// Stores credentials as an encrypted JSON file in Application Support,
/// using a random 256-bit key stored in the macOS Keychain.
enum ClaudeCredentials {
    private static let fileName = "claude-oauth.enc"
    private static let keychainService = "com.unstablemind.tamagotchai"
    private static let keychainAccount = "encryption-key"

    // Retrieves or generates the encryption key from the macOS Keychain.
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var encryptionKey: SymmetricKey = {
        if let existingKey = loadKeyFromKeychain() {
            return existingKey
        }

        // Generate a new random 256-bit key and store it.
        let newKey = SymmetricKey(size: .bits256)
        if storeKeyInKeychain(newKey) {
            logger.info("Generated and stored new encryption key in Keychain")
        } else {
            logger.error("Failed to store encryption key in Keychain — credentials will not persist across installs")
        }
        return newKey
    }()

    // MARK: - Keychain

    private static func loadKeyFromKeychain() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            if status != errSecItemNotFound {
                logger.warning("Keychain read failed with status: \(status)")
            }
            return nil
        }

        return SymmetricKey(data: data)
    }

    private static func storeKeyInKeychain(_ key: SymmetricKey) -> Bool {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // Delete any existing item first.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - File Storage

    private static func credentialsURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Tamagotchai", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func save(_ credentials: OAuthCredentials) throws {
        do {
            let data = try JSONEncoder().encode(credentials)
            let sealed = try ChaChaPoly.seal(data, using: encryptionKey)
            let combined = sealed.combined
            try combined.write(to: credentialsURL())
            logger.info("Credentials saved successfully")
        } catch {
            logger.error("Failed to save credentials: \(error.localizedDescription)")
            throw error
        }
    }

    static func load() -> OAuthCredentials? {
        let url: URL
        do {
            url = try credentialsURL()
        } catch {
            logger.error("Failed to resolve credentials URL: \(error.localizedDescription)")
            return nil
        }

        let combined: Data
        do {
            combined = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read credentials file: \(error.localizedDescription)")
            return nil
        }

        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            logger.error("Failed to create sealed box from credentials data: \(error.localizedDescription)")
            return nil
        }

        let data: Data
        do {
            data = try ChaChaPoly.open(box, using: encryptionKey)
        } catch {
            logger.error("Failed to decrypt credentials: \(error.localizedDescription)")
            return nil
        }

        do {
            let credentials = try JSONDecoder().decode(OAuthCredentials.self, from: data)
            logger.info("Credentials loaded successfully")
            return credentials
        } catch {
            logger.error("Failed to decode credentials JSON: \(error.localizedDescription)")
            return nil
        }
    }

    static func delete() {
        do {
            let url = try credentialsURL()
            try FileManager.default.removeItem(at: url)
            logger.info("Credentials deleted successfully")
        } catch {
            logger.error("Failed to delete credentials: \(error.localizedDescription)")
        }
    }
}
