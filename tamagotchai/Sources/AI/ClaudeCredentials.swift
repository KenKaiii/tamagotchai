import CryptoKit
import Foundation
import os

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
/// avoiding macOS Keychain password prompts that occur on every rebuild
/// during development (Keychain ties access to the exact code signature).
enum ClaudeCredentials {
    private static let fileName = "claude-oauth.enc"

    /// A stable device-derived key so credentials survive rebuilds.
    /// Falls back to a hardcoded key if the hardware UUID is unavailable.
    private nonisolated(unsafe) static var encryptionKey: SymmetricKey = {
        if let uuid = getHardwareUUID() {
            let seed = "com.unstablemind.tamagotchai.\(uuid)"
            let hash = SHA256.hash(data: Data(seed.utf8))
            return SymmetricKey(data: hash)
        } else {
            logger.warning("Hardware UUID unavailable, using fallback encryption key")
            let seed = "com.unstablemind.tamagotchai.fallback-key"
            let hash = SHA256.hash(data: Data(seed.utf8))
            return SymmetricKey(data: hash)
        }
    }()

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

    /// Reads the hardware UUID from IOKit (stable across rebuilds).
    private static func getHardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        let key = kIOPlatformUUIDKey as CFString
        guard let uuid = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        else { return nil }
        return uuid
    }
}
