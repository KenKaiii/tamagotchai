import Foundation

/// A single content block in a Claude API response.
enum ContentBlock: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
}

/// Token usage reported by the Anthropic API. Cache fields are 0 when the
/// request misses the cache or when the provider doesn't support caching.
struct TokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    /// Percentage of input tokens served from cache (0–100). 0 when there are
    /// no input tokens at all.
    var cacheHitRatio: Double {
        let total = inputTokens + cacheCreationInputTokens + cacheReadInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total) * 100.0
    }
}

/// Structured response from an API call (Anthropic or OpenAI-compatible).
struct ClaudeResponse: @unchecked Sendable {
    let content: [ContentBlock]
    let stopReason: String?
    /// Accumulated reasoning/thinking content from OpenAI-compatible providers (Moonshot).
    /// Must be round-tripped in assistant messages when thinking is enabled.
    let reasoningContent: String?
    /// Token usage for this request — nil if the provider didn't report it.
    let usage: TokenUsage?

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

extension ClaudeResponse {
    /// Convenience initializer for call sites that don't have usage data.
    init(content: [ContentBlock], stopReason: String?, reasoningContent: String?) {
        self.init(content: content, stopReason: stopReason, reasoningContent: reasoningContent, usage: nil)
    }
}
