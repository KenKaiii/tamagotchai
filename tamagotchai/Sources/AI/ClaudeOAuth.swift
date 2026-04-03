import AppKit
import CryptoKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "oauth"
)

/// Handles the OAuth PKCE flow for Anthropic's Claude API.
@MainActor
enum ClaudeOAuth {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private static let authorizeURL = "https://claude.ai/oauth/authorize"
    private static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    /// Pending login flow state.
    private(set) static var pendingVerifier: String?
    private(set) static var pendingState: String?

    // MARK: - PKCE

    private static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Login Flow

    /// Opens the browser with the OAuth authorize URL. Returns the state string.
    @MainActor
    static func startLogin() {
        let verifier = generateVerifier()
        let state = UUID().uuidString
        pendingVerifier = verifier
        pendingState = state
        logger.info("Starting OAuth login flow (state: \(state))")

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Completes login by parsing the raw "code#state" string from the user, exchanging the code,
    /// and saving credentials. Returns the credentials on success.
    @discardableResult
    static func completeLogin(rawCode: String) async throws -> OAuthCredentials {
        logger.info("Completing login (code length: \(rawCode.count))")
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard parts.count == 2 else {
            logger.error("Invalid code format — expected code#state")
            throw OAuthError.invalidCodeFormat
        }

        let code = String(parts[0])
        let state = String(parts[1])

        guard let verifier = pendingVerifier, state == pendingState else {
            logger.error("State mismatch — expected: \(pendingState ?? "nil"), got: \(state)")
            throw OAuthError.stateMismatch
        }

        let credentials = try await exchangeCode(code: code, state: state, verifier: verifier)
        try ClaudeCredentials.save(credentials)

        pendingVerifier = nil
        pendingState = nil

        logger.info("Login completed successfully")
        return credentials
    }

    // MARK: - Token Exchange

    static func exchangeCode(code: String, state: String, verifier: String) async throws -> OAuthCredentials {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        return try await tokenRequest(body: body)
    }

    static func refreshToken(_ refreshToken: String) async throws -> OAuthCredentials {
        logger.info("Refreshing OAuth token")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ]
        return try await tokenRequest(body: body)
    }

    // MARK: - Private

    private static func tokenRequest(body: [String: String]) async throws -> OAuthCredentials {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token exchange failed — HTTP \(statusCode): \(bodyString)")
            throw OAuthError.tokenExchangeFailed(statusCode: statusCode, body: bodyString)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        return OAuthCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }

    // MARK: - Types

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    enum OAuthError: LocalizedError {
        case invalidCodeFormat
        case stateMismatch
        case tokenExchangeFailed(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidCodeFormat:
                "Invalid login code format. Expected code#state."
            case .stateMismatch:
                "Login state mismatch. Please try logging in again."
            case let .tokenExchangeFailed(statusCode, body):
                "Token exchange failed (HTTP \(statusCode)): \(body)"
            }
        }
    }
}
