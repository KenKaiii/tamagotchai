import CryptoKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "provider-store"
)

/// Credential for a single provider — API key or OAuth tokens.
struct ProviderCredential: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let accountId: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var isOAuth: Bool {
        refreshToken != nil
    }

    /// Create from a simple API key.
    static func apiKey(_ key: String) -> ProviderCredential {
        ProviderCredential(accessToken: key, refreshToken: nil, expiresAt: nil, accountId: nil)
    }

    /// Create from OAuth token exchange result.
    static func oauth(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountId: String
    ) -> ProviderCredential {
        ProviderCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountId: accountId
        )
    }
}

/// Persisted state for all provider credentials and model selection.
private struct StoreData: Codable {
    var credentials: [String: ProviderCredential]
    var selectedModelId: String?

    static let empty = StoreData(credentials: [:], selectedModelId: nil)
}

/// Manages API keys for all providers and persists selected model.
@MainActor
final class ProviderStore {
    static let shared = ProviderStore()

    private var data: StoreData
    private static let fileName = "provider-store.enc"

    private init() {
        data = Self.loadFromDisk() ?? .empty
    }

    // MARK: - Credentials

    func hasCredentials(for provider: AIProvider) -> Bool {
        data.credentials[provider.rawValue] != nil
    }

    func credential(for provider: AIProvider) -> ProviderCredential? {
        data.credentials[provider.rawValue]
    }

    func setCredential(_ credential: ProviderCredential, for provider: AIProvider) {
        data.credentials[provider.rawValue] = credential
        save()
    }

    func removeCredential(for provider: AIProvider) {
        data.credentials.removeValue(forKey: provider.rawValue)
        // If the selected model belongs to this provider, clear it
        if let modelId = data.selectedModelId,
           let model = ModelRegistry.model(withId: modelId),
           model.provider == provider
        {
            data.selectedModelId = nil
        }
        save()
    }

    /// Returns the access token for the given provider.
    /// For OAuth providers, auto-refreshes expired tokens.
    func validAccessToken(for provider: AIProvider) async throws -> String {
        guard let cred = data.credentials[provider.rawValue] else {
            throw ProviderStoreError.noCredentials(provider)
        }

        // Auto-refresh expired OAuth tokens
        if cred.isOAuth, cred.isExpired, let refreshToken = cred.refreshToken {
            logger.info("Token expired for \(provider.displayName), refreshing…")
            let refreshed = try await OpenAIOAuth.shared.refresh(refreshToken: refreshToken)
            let newCred = ProviderCredential.oauth(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                accountId: refreshed.accountId
            )
            data.credentials[provider.rawValue] = newCred
            save()
            return newCred.accessToken
        }

        return cred.accessToken
    }

    // MARK: - Model Selection

    var selectedModel: ModelInfo {
        if let id = data.selectedModelId, let model = ModelRegistry.model(withId: id) {
            if hasCredentials(for: model.provider) {
                return model
            }
        }
        // Fall back to first available model
        if let first = ModelRegistry.availableModels().first {
            return first
        }
        // Ultimate fallback
        return ModelRegistry.defaultModel(for: .moonshot)
    }

    func setSelectedModel(_ model: ModelInfo) {
        data.selectedModelId = model.id
        save()
    }

    /// Whether any provider has credentials configured.
    var hasAnyCredentials: Bool {
        !data.credentials.isEmpty
    }

    // MARK: - Validation

    /// Validates an API key by hitting the provider's models endpoint.
    /// Returns nil on success, or an error message on failure.
    nonisolated func validateApiKey(_ key: String, for provider: AIProvider) async -> String? {
        guard let url = URL(string: provider.modelsURL) else {
            return "Invalid provider URL."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Unexpected response from server."
            }
            switch http.statusCode {
            case 200 ..< 300:
                return nil
            case 401, 403:
                return "Invalid API key. Check and try again."
            default:
                return "Validation failed (HTTP \(http.statusCode)). The key may still work — try sending a message."
            }
        } catch {
            return "Couldn't reach \(provider.displayName). Check your internet and try again."
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let jsonData = try JSONEncoder().encode(data)
            let key = ClaudeCredentials.sharedEncryptionKey
            let sealed = try ChaChaPoly.seal(jsonData, using: key)
            try sealed.combined.write(to: Self.fileURL())
            logger.info("Provider store saved")
        } catch {
            logger.error("Failed to save provider store: \(error.localizedDescription)")
        }
    }

    private static func loadFromDisk() -> StoreData? {
        do {
            let url = try fileURL()
            let combined = try Data(contentsOf: url)
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let key = ClaudeCredentials.sharedEncryptionKey
            let jsonData = try ChaChaPoly.open(box, using: key)
            return try JSONDecoder().decode(StoreData.self, from: jsonData)
        } catch {
            return nil
        }
    }

    private static func fileURL() throws -> URL {
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

    // MARK: - Errors

    enum ProviderStoreError: LocalizedError {
        case noCredentials(AIProvider)

        var errorDescription: String? {
            switch self {
            case let .noCredentials(provider):
                "No API key configured for \(provider.displayName). Add one in Settings."
            }
        }
    }
}
