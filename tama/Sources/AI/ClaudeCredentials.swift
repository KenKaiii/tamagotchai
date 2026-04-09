import CryptoKit
import Foundation
import os
import Security

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "credentials"
)

/// Keychain-backed encryption key used to secure all API credentials.
/// This key encrypts your Claude, OpenAI, and other provider tokens.
enum ClaudeCredentials {
    /// Shown in macOS keychain permission prompts.
    /// Using "Tama" instead of bundle ID for clearer user-facing messages.
    private static let keychainService = "Tama"
    private static let keychainAccount = "encryption-key"

    // Retrieves or generates the encryption key from the macOS Keychain.
    // Shared with ProviderStore for consistent encryption.
    nonisolated(unsafe) static var sharedEncryptionKey: SymmetricKey = {
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
}
