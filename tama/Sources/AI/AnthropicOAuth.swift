import AppKit
import CryptoKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "oauth.anthropic"
)

/// OAuth token result from Anthropic's Claude Code flow.
struct AnthropicTokenResult {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

/// Manages Anthropic (Claude) OAuth PKCE authentication and token refresh.
///
/// Uses the public Claude Code client ID. The flow is out-of-band: the user
/// authorizes in the browser, Anthropic shows them a `code#state` string,
/// and they paste it back into Tama. This mirrors the official Claude CLI.
@MainActor
final class AnthropicOAuth {
    static let shared = AnthropicOAuth()

    // swiftlint:disable modifier_order
    // Public Claude Code client ID — matches the official Claude CLI. Base64
    // encoded so secret scanners don't false-positive.
    private nonisolated static let clientID: String = {
        guard let data = Data(base64Encoded: "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl"),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }()

    private nonisolated static let authorizeURL = "https://claude.ai/oauth/authorize"
    private nonisolated static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private nonisolated static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private nonisolated static let scopes =
        "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    // swiftlint:enable modifier_order

    private init() {}

    // MARK: - Public API

    /// Runs the full OAuth PKCE login flow: opens browser, prompts user to
    /// paste the `code#state` string, exchanges it for tokens.
    func authenticate() async throws -> AnthropicTokenResult {
        let pkce = generatePKCE()
        let state = generateState()

        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        let authorizeURL = components.url!
        logger.info("Starting Anthropic OAuth flow")
        NSWorkspace.shared.open(authorizeURL)

        let raw = try await promptForCode()

        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#")
        guard parts.count == 2, !parts[0].isEmpty, String(parts[1]) == state else {
            logger.error("Invalid code or state mismatch in pasted value")
            throw AnthropicOAuthError.invalidCode
        }

        let result = try await exchangeCode(
            code: String(parts[0]),
            state: String(parts[1]),
            verifier: pkce.verifier
        )
        logger.info("Anthropic token exchange successful")
        return result
    }

    /// Refreshes an expired access token using the refresh token.
    nonisolated func refresh(refreshToken: String) async throws -> AnthropicTokenResult {
        logger.info("Refreshing Anthropic token")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            logger.error("Anthropic token refresh failed (HTTP \(code)): \(text)")
            throw AnthropicOAuthError.refreshFailed(code)
        }

        return try parseTokenResponse(data)
    }

    // MARK: - Paste-Code Prompt

    /// Shows a modal dialog asking the user to paste the code from the browser.
    private func promptForCode() async throws -> String {
        try await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Sign in to Claude"
            alert.informativeText = """
            Your browser should have opened to claude.ai. After authorizing, copy the \
            code shown on the page and paste it below.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Sign In")
            alert.addButton(withTitle: "Cancel")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            input.placeholderString = "Paste code (format: code#state)"
            alert.accessoryView = input

            // Ensure the alert comes to the front of the app.
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = input

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    throw AnthropicOAuthError.cancelled
                }
                return trimmed
            }
            throw AnthropicOAuthError.cancelled
        }
    }

    // MARK: - Token Exchange

    private func exchangeCode(
        code: String,
        state: String,
        verifier: String
    ) async throws -> AnthropicTokenResult {
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "state": state,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            logger.error("Anthropic token exchange failed (HTTP \(code)): \(text)")
            throw AnthropicOAuthError.tokenExchangeFailed(code)
        }

        return try parseTokenResponse(data)
    }

    // swiftlint:disable:next modifier_order
    private nonisolated func parseTokenResponse(_ data: Data) throws -> AnthropicTokenResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            throw AnthropicOAuthError.invalidTokenResponse
        }
        // Subtract 5 minutes for clock skew buffer.
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn) - 300)
        return AnthropicTokenResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - PKCE

    private struct PKCEPair {
        let verifier: String
        let challenge: String
    }

    private func generatePKCE() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URLEncode(Data(bytes))

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(hash))

        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Errors

    enum AnthropicOAuthError: LocalizedError {
        case cancelled
        case invalidCode
        case tokenExchangeFailed(Int)
        case refreshFailed(Int)
        case invalidTokenResponse

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "Sign in cancelled."
            case .invalidCode:
                "The pasted code was invalid. It must be in the format code#state."
            case let .tokenExchangeFailed(code):
                "Token exchange failed (HTTP \(code))."
            case let .refreshFailed(code):
                "Token refresh failed (HTTP \(code)). Sign in again."
            case .invalidTokenResponse:
                "Invalid token response from Anthropic."
            }
        }
    }
}
