import Foundation
import os

/// Singleton service for calling AI APIs. Supports Anthropic (Claude) and
/// OpenAI-compatible providers (Moonshot/Kimi) via ProviderStore.
@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let logger = Logger(
        subsystem: "com.unstablemind.tamagotchai",
        category: "claude"
    )

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

    var isLoggedIn: Bool { ProviderStore.shared.hasAnyCredentials }

    private init() {}

    /// The currently selected model from ProviderStore.
    var currentModel: ModelInfo {
        ProviderStore.shared.selectedModel
    }

    // MARK: - API

    /// Sends a conversation with tool definitions and streams events back.
    func sendWithTools(
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String? = nil,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let model = currentModel
        logger.info("sendWithTools — model: \(model.id), messages: \(messages.count), tools: \(tools.count)")

        if model.provider.usesCodexAPI {
            return try await streamCodexRequest(
                model: model,
                messages: messages,
                tools: tools,
                systemPrompt: systemPrompt,
                onEvent: onEvent
            )
        }

        if model.provider.usesAnthropicAPI {
            return try await streamAnthropicRequest(
                model: model,
                messages: messages,
                tools: tools,
                systemPrompt: systemPrompt,
                onEvent: onEvent
            )
        }

        return try await streamOpenAIRequest(
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt,
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

    // MARK: - Codex Streaming (OpenAI)

    private func streamCodexRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        guard let accountId = ProviderStore.shared.credential(for: model.provider)?.accountId else {
            throw ClaudeServiceError.notLoggedIn
        }

        // Build system prompt with dynamic context
        var fullSystemPrompt = baseSystemPrompt
        if let extra = systemPrompt {
            fullSystemPrompt += "\n\n" + extra
        }
        fullSystemPrompt += "\n\n" + dynamicContext()

        let request = try CodexRequestBuilder.buildRequest(
            token: token,
            accountId: accountId,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: fullSystemPrompt
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("Codex API failed — HTTP \(code): \(body)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = CodexStreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    // MARK: - Anthropic-Compatible Streaming (MiniMax)

    private func streamAnthropicRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        let request = try buildAnthropicRequest(
            token: token,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("Anthropic API failed — HTTP \(code): \(body)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = StreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    private func buildAnthropicRequest(
        token: String,
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        systemPrompt: String?
    ) throws -> URLRequest {
        let url = URL(string: model.provider.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("tamagotchai/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        // Build system prompt with dynamic context
        var fullSystemPrompt = baseSystemPrompt
        if let extra = systemPrompt {
            fullSystemPrompt += "\n\n" + extra
        }
        fullSystemPrompt += "\n\n" + dynamicContext()

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": model.maxOutputTokens,
            "stream": true,
            "system": fullSystemPrompt,
            "messages": messages,
        ]

        // Add tools if present (Anthropic native format — no conversion needed)
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - OpenAI-Compatible Streaming (Moonshot/Xiaomi)

    private func streamOpenAIRequest(
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]],
        systemPrompt: String?,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ClaudeResponse {
        let token = try await ProviderStore.shared.validAccessToken(for: model.provider)
        let request = try buildOpenAIRequest(
            token: token,
            model: model,
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt
        )

        let (bytes, response) = try await streamingSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
                if bodyData.count > 4096 { break }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? "<no body>"
            logger.error("OpenAI API failed — HTTP \(code): \(body)")
            throw ClaudeServiceError.apiError(statusCode: code, body: body)
        }

        let parser = OpenAIStreamParser(onEvent: onEvent)
        try await parser.parse(bytes: bytes)
        let result = parser.buildResponse()
        onEvent(.response(result))
        return result
    }

    private func buildOpenAIRequest(
        token: String,
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        systemPrompt: String?
    ) throws -> URLRequest {
        let url = URL(string: model.provider.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("tamagotchai/1.0", forHTTPHeaderField: "User-Agent")

        // Build system message content
        var systemContent = baseSystemPrompt
        if let extra = systemPrompt {
            systemContent += "\n\n" + extra
        }
        systemContent += "\n\n" + dynamicContext()

        // OpenAI format: system message as first message in array
        var openAIMessages: [[String: Any]] = [
            ["role": "system", "content": systemContent],
        ]

        // Convert Anthropic-format messages to OpenAI format
        for msg in messages {
            openAIMessages.append(contentsOf: convertMessageToOpenAI(msg))
        }

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": model.maxOutputTokens,
            "stream": true,
            "messages": openAIMessages,
        ]

        // Convert tools from Anthropic format to OpenAI function calling format
        if let tools, !tools.isEmpty {
            var openAITools: [[String: Any]] = tools.compactMap { convertToolToOpenAI($0) }

            // Moonshot: inject built-in $web_search tool
            if model.provider == .moonshot {
                openAITools.append([
                    "type": "builtin_function",
                    "function": ["name": "$web_search"],
                ])
            }

            body["tools"] = openAITools
        }

        // All providers: disable thinking to avoid latency. When adding new providers,
        // ensure thinking stays disabled unless explicitly opted in by the user.
        if model.provider.usesCustomThinkingParam {
            // Moonshot/Xiaomi use a custom "thinking" body parameter
            body["thinking"] = ["type": "disabled"]
        } else if model.provider == .openai {
            // OpenAI uses "reasoning_effort" to control thinking
            body["reasoning_effort"] = "none"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        return request
    }

    // MARK: - Format Conversion

    /// Convert an Anthropic-format message to OpenAI format.
    /// Returns an array because one Anthropic message (with multiple tool_results)
    /// may expand into multiple OpenAI messages.
    private func convertMessageToOpenAI(_ msg: [String: Any]) -> [[String: Any]] {
        guard let role = msg["role"] as? String else { return [msg] }

        // Simple string content
        if let content = msg["content"] as? String {
            return [["role": role, "content": content]]
        }

        // Array content (Anthropic uses content arrays for tool results)
        guard let blocks = msg["content"] as? [[String: Any]] else { return [msg] }

        // For assistant messages with tool_use blocks
        if role == "assistant" {
            var content = ""
            var toolCalls: [[String: Any]] = []

            for block in blocks {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    content += text
                } else if type == "tool_use",
                          let id = block["id"] as? String,
                          let name = block["name"] as? String,
                          let input = block["input"]
                {
                    let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                    let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": argsStr,
                        ],
                    ])
                }
            }

            var result: [String: Any] = ["role": "assistant"]
            if !content.isEmpty { result["content"] = content }
            if !toolCalls.isEmpty { result["tool_calls"] = toolCalls }
            // Round-trip reasoning_content if present (for providers with thinking)
            if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty {
                result["reasoning_content"] = reasoning
            }
            return [result]
        }

        // For user messages with tool_result blocks — each becomes a separate message
        if role == "user" {
            var converted: [[String: Any]] = []
            for block in blocks {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    converted.append(["role": "user", "content": text])
                } else if type == "tool_result",
                          let toolUseId = block["tool_use_id"] as? String,
                          let content = block["content"] as? String
                {
                    converted.append([
                        "role": "tool",
                        "tool_call_id": toolUseId,
                        "content": content,
                    ])
                }
            }
            if !converted.isEmpty { return converted }
        }

        return [msg]
    }

    /// Convert an Anthropic tool definition to OpenAI function calling format.
    private func convertToolToOpenAI(_ tool: [String: Any]) -> [String: Any]? {
        // Skip Anthropic server-side tools (web_search_20250305, etc.)
        if let type = tool["type"] as? String, type.contains("web_search") {
            return nil
        }

        guard let name = tool["name"] as? String else { return nil }

        var function: [String: Any] = ["name": name]
        if let desc = tool["description"] as? String {
            function["description"] = desc
        }
        if let schema = tool["input_schema"] as? [String: Any] {
            function["parameters"] = schema
        }

        return [
            "type": "function",
            "function": function,
        ]
    }

    // MARK: - Errors

    enum ClaudeServiceError: LocalizedError {
        case notLoggedIn
        case apiError(statusCode: Int, body: String)
        case streamError(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                "Not logged in. Add an API key in Settings."
            case let .apiError(statusCode, body):
                "API error (HTTP \(statusCode)): \(body)"
            case let .streamError(message):
                "Stream error: \(message)"
            }
        }
    }
}
