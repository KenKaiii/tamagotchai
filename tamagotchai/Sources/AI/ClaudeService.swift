import Foundation
import os

/// Singleton service for calling the Anthropic Messages API with OAuth credentials.
@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let logger = Logger(
        subsystem: "com.unstablemind.tamagotchai",
        category: "claude"
    )
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"

    /// Dedicated session with resource timeout so streaming connections
    /// don't hang forever on network issues (default is 7 days).
    private let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// Base system prompt — static, cacheable.
    let baseSystemPrompt = """
    You are Tamagotchai, a personal assistant living on the user's desktop.

    ## personality & tone

    Talk like texting a close friend. Chill, casual, real.

    - lowercase always (except proper nouns, acronyms, or emphasis)
    - skip periods at end of messages
    - emojis sparingly
    - direct and concise - no fluff, no corporate speak
    - joke around, be a little sarcastic, keep it fun
    - if something's unclear, ask instead of guessing
    - you help with tasks, answer questions, and keep them motivated
    - never say "I'm an AI" or "as a language model" — you're their homie on the desktop
    """

    /// Current credentials — loaded from encrypted file on init.
    private(set) var credentials: OAuthCredentials?

    var isLoggedIn: Bool { credentials != nil }

    private init() {
        credentials = ClaudeCredentials.load()
    }

    /// Update credentials after login/refresh.
    func setCredentials(_ creds: OAuthCredentials?) {
        credentials = creds
    }

    func logout() {
        credentials = nil
        ClaudeCredentials.delete()
    }

    // MARK: - API

    /// Sends a conversation with tool definitions and streams events back.
    /// Returns a structured ClaudeResponse with both text and tool_use blocks.
    func sendWithTools(
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String? = nil,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        logger.info("sendWithTools — messages: \(messages.count), tools: \(tools.count)")
        let token = try await validAccessToken()
        return try await streamRequestWithTools(
            token: token,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt,
            onEvent: onEvent
        )
    }

    // MARK: - Token Management

    private func validAccessToken() async throws -> String {
        guard var creds = credentials else {
            logger.warning("Access token requested but not logged in")
            throw ClaudeServiceError.notLoggedIn
        }

        if creds.isExpired {
            logger.info("Token expired, refreshing…")
            do {
                let refreshed = try await ClaudeOAuth.refreshToken(
                    creds.refreshToken
                )
                try ClaudeCredentials.save(refreshed)
                credentials = refreshed
                creds = refreshed
                logger.info("Token refreshed successfully, expires at \(refreshed.expiresAt)")
            } catch {
                logger.error("Token refresh failed: \(error.localizedDescription)")
                throw error
            }
        }

        return creds.accessToken
    }

    // MARK: - Tool-aware Streaming

    private func streamRequestWithTools(
        token: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let request = try buildRequest(
            token: token,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt
        )

        let (bytes, response) = try await streamingSession.bytes(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Drain the error body so we get the actual API error message.
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("API request failed — HTTP \(code): \(body)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        return try await parseToolStream(
            bytes: bytes,
            onEvent: onEvent
        )
    }

    // MARK: - Dynamic Context

    private func dynamicContext() -> String {
        let now = Date()
        let dateStr = now.formatted(
            .dateTime.weekday(.wide).month(.wide).day().year()
        )
        let timeStr = now.formatted(.dateTime.hour().minute())
        let tz = TimeZone.current

        let seconds = tz.secondsFromGMT()
        let h = abs(seconds) / 3600
        let m = (abs(seconds) % 3600) / 60
        let sign = seconds >= 0 ? "+" : "-"
        let offsetString = m == 0
            ? "\(sign)\(h)"
            : String(format: "%@%d:%02d", sign, h, m)

        return """
        [current context]
        date: \(dateStr)
        time: \(timeStr)
        timezone: \(tz.identifier) (UTC\(offsetString))
        platform: macOS
        """
    }

    // MARK: - Request Building

    private func buildRequest(
        token: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        systemPrompt: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "2023-06-01",
            forHTTPHeaderField: "anthropic-version"
        )
        request.setValue(
            "claude-code-20250219,oauth-2025-04-20,prompt-caching-2024-07-31",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "tamagotchai/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("tamagotchai", forHTTPHeaderField: "x-app")

        var systemBlocks: [[String: Any]] = []

        // Base prompt — static, cached
        var baseBlock: [String: Any] = [
            "type": "text",
            "text": baseSystemPrompt,
        ]
        if systemPrompt != nil {
            // Cache the base block when there's extra context after it
            baseBlock["cache_control"] = ["type": "ephemeral"]
        }
        systemBlocks.append(baseBlock)

        // Extra context (tools description, etc.) — cached
        if let extra = systemPrompt {
            systemBlocks.append([
                "type": "text",
                "text": extra,
                "cache_control": ["type": "ephemeral"],
            ])
        }

        // Dynamic context — current time, never cached
        systemBlocks.append([
            "type": "text",
            "text": dynamicContext(),
        ])

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "stream": true,
            "system": systemBlocks,
            "messages": messages,
        ]

        // Merge client tools with server-side tools (web search)
        var allTools: [[String: Any]] = tools ?? []
        allTools.append([
            "type": "web_search_20250305",
            "name": "web_search",
            "max_uses": 5,
        ])
        body["tools"] = allTools

        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )

        // Prevent indefinite hangs on dropped connections during streaming.
        // Default timeoutInterval is 60s which is fine for initial response.
        request.timeoutInterval = 120

        return request
    }

    // MARK: - Stream Parsing

    private func parseToolStream(
        bytes: URLSession.AsyncBytes,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let parser = StreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    // MARK: - Errors

    enum ClaudeServiceError: LocalizedError {
        case notLoggedIn
        case apiError(statusCode: Int, body: String)
        case streamError(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                "Not logged in to Claude. Use the menu bar to log in."
            case let .apiError(statusCode, body):
                "Claude API error (HTTP \(statusCode)): \(body)"
            case let .streamError(message):
                "Claude error: \(message)"
            }
        }
    }
}
