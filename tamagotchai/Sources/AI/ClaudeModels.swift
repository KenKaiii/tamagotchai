import Foundation

/// A single content block in a Claude API response.
enum ContentBlock: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    /// Server-side tool (web_search) — executed by Anthropic, passed through as-is.
    case serverToolUse(id: String, name: String, input: [String: Any])
    /// Server-side tool result (web_search_tool_result) — passed through as-is.
    case serverToolResult(toolUseId: String, content: [[String: Any]])
    /// Server-side tool result error (web_search_tool_result with error).
    case serverToolResultError(toolUseId: String, errorCode: String)
}

/// Structured response from a Claude API call.
struct ClaudeResponse: @unchecked Sendable {
    let content: [ContentBlock]
    let stopReason: String?

    var textContent: String {
        content.compactMap { block in
            if case let .text(text) = block { return text }
            return nil
        }.joined()
    }

    var toolUseCalls: [(id: String, name: String, input: [String: Any])] {
        content.compactMap { block in
            if case let .toolUse(id, name, input) = block {
                return (id: id, name: name, input: input)
            }
            return nil
        }
    }
}

/// Event streamed during a sendWithTools call.
enum StreamEvent: Sendable {
    case textDelta(String)
    case toolUseStart(id: String, name: String)
    case response(ClaudeResponse)
}
