import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "gemini-stream"
)

/// Parses SSE events from Google's Cloud Code Assist
/// `v1internal:streamGenerateContent?alt=sse` endpoint.
///
/// Each `data:` line contains a JSON object shaped like
/// `{"response": {"candidates":[{"content":{"parts":[...]}, "finishReason":"..."}], ...}}`.
@MainActor
final class GeminiStreamParser {
    private let onEvent: @Sendable (StreamEvent) -> Void
    private var contentBlocks: [ContentBlock] = []
    private var stopReason: String?

    // Text accumulation (visible output; `thought: true` parts are skipped).
    private var textParts: [String] = []

    // Tool calls emitted in-order as we see them.
    private var sawToolCall = false

    init(onEvent: @escaping @Sendable (StreamEvent) -> Void) {
        self.onEvent = onEvent
    }

    func parse(bytes: URLSession.AsyncBytes) async throws {
        for try await line in bytes.lines {
            try processLine(line)
        }
        flushText()
    }

    func buildResponse() -> ClaudeResponse {
        let textCount = contentBlocks.count(where: { if case .text = $0 { return true }
            return false
        })
        let toolCount = contentBlocks.count(where: { if case .toolUse = $0 { return true }
            return false
        })
        // swiftformat:disable:next redundantSelf
        logger.info("Gemini stream done — \(textCount) text, \(toolCount) tool_use, stop=\(self.stopReason ?? "nil")")
        return ClaudeResponse(
            content: contentBlocks,
            stopReason: stopReason,
            reasoningContent: nil
        )
    }

    // MARK: - Line Processing

    private func processLine(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return }

        guard let data = payload.data(using: .utf8) else { return }

        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Gemini stream: non-dictionary JSON: \(payload.prefix(200))")
                return
            }
            obj = parsed
        } catch {
            logger.warning("Gemini stream: JSON parse failed: \(error.localizedDescription) — \(payload.prefix(200))")
            return
        }

        guard let response = obj["response"] as? [String: Any] else { return }
        try processResponse(response)
    }

    private func processResponse(_ response: [String: Any]) throws {
        guard let candidates = response["candidates"] as? [[String: Any]],
              let candidate = candidates.first
        else { return }

        if let content = candidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]]
        {
            for part in parts {
                processPart(part)
            }
        }

        if let finishReason = candidate["finishReason"] as? String {
            stopReason = mapFinishReason(finishReason)
        }
    }

    private func processPart(_ part: [String: Any]) {
        let isThought = (part["thought"] as? Bool) == true

        if let text = part["text"] as? String, !text.isEmpty {
            // Skip thinking content from visible output.
            if isThought { return }
            textParts.append(text)
            onEvent(.textDelta(text))
            return
        }

        if let functionCall = part["functionCall"] as? [String: Any] {
            flushText()

            let name = (functionCall["name"] as? String) ?? ""
            let providedId = functionCall["id"] as? String
            let id: String = if let providedId, !providedId.isEmpty {
                providedId
            } else {
                "toolu_\(name)_\(Int(Date().timeIntervalSince1970 * 1000))"
            }

            let args = (functionCall["args"] as? [String: Any]) ?? [:]

            onEvent(.toolUseStart(id: id, name: name))
            contentBlocks.append(.toolUse(id: id, name: name, input: args))
            sawToolCall = true
        }
    }

    private func mapFinishReason(_ reason: String) -> String {
        switch reason {
        case "STOP":
            sawToolCall ? "tool_use" : "end_turn"
        case "MAX_TOKENS":
            "max_tokens"
        default:
            // SAFETY, RECITATION, OTHER etc. — surface as end_turn; errors
            // are already surfaced via the HTTP layer.
            sawToolCall ? "tool_use" : "end_turn"
        }
    }

    private func flushText() {
        guard !textParts.isEmpty else { return }
        contentBlocks.append(.text(textParts.joined()))
        textParts = []
    }
}
