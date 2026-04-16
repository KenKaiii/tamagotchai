import Foundation
@testable import Tama

/// Test helper that reads provider credentials from the local `gg` CLI's
/// auth store (`~/.gg/auth.json`) so live API tests can run without copying
/// keys into Tama's encrypted `provider-store.enc`. Falls back to environment
/// variables (`TAMA_<PROVIDER>_KEY`) when the file is unavailable, e.g. CI.
enum GGAuthBridge {
    /// Returns the access token for a given provider, or nil if neither the
    /// local gg auth store nor the env var fallback yields a credential.
    static func accessToken(for provider: AIProvider) -> String? {
        if let envKey = envFallback(for: provider), !envKey.isEmpty {
            return envKey
        }
        guard let entry = ggAuthEntry(for: provider) else { return nil }
        let token = entry["accessToken"] as? String
        return (token?.isEmpty == false) ? token : nil
    }

    /// Returns the OpenAI ChatGPT account ID required by the Codex `/responses`
    /// endpoint, or nil if not present (e.g. provider isn't openai).
    static func accountId(for provider: AIProvider) -> String? {
        guard provider == .openai else { return nil }
        return ggAuthEntry(for: provider)?["accountId"] as? String
    }

    // MARK: - Private

    private static func envFallback(for provider: AIProvider) -> String? {
        let key = "TAMA_\(provider.rawValue.uppercased())_KEY"
        return ProcessInfo.processInfo.environment[key]
    }

    private static func ggAuthEntry(for provider: AIProvider) -> [String: Any]? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".gg/auth.json")
        guard fileManager.isReadableFile(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json[provider.rawValue] as? [String: Any]
    }
}
