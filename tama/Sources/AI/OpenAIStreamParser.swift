import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "openai-stream"
)

/// Parses SSE events from OpenAI-compatible streaming APIs.
///
/// OpenAI streams use `data: {json}` lines with `choices[0].delta` containing
/// content, tool_calls, and reasoning_content. Terminated by `data: [DONE]`.
@MainActor
final class OpenAIStreamParser {
    private let onEvent: @Sendable (StreamEvent) -> Void
    private var contentBlocks: [ContentBlock] = []
    private var stopReason: String?

    // Text accumulation
    private var textParts: [String] = []

    // Reasoning/thinking content accumulation (some providers send reasoning_content in deltas)
    private var reasoningParts: [String] = []

    // Tool call accumulation — OpenAI streams tool calls incrementally by index
    private var activeToolCalls: [Int: ToolCallAccumulator] = [:]

    private struct ToolCallAccumulator {
        var id: String
        var name: String
        var arguments: String
    }

    init(onEvent: @escaping @Sendable (StreamEvent) -> Void) {
        self.onEvent = onEvent
    }

    func parse(bytes: URLSession.AsyncBytes) async throws {
        for try await line in bytes.lines {
            try processLine(line)
        }
        flushAll()
    }

    func buildResponse() -> ClaudeResponse {
        let textCount = contentBlocks.count(where: { if case .text = $0 { return true }
            return false
        })
        let toolCount = contentBlocks.count(where: { if case .toolUse = $0 { return true }
            return false
        })
        // swiftformat:disable:next redundantSelf
        logger.info("OpenAI stream done — \(textCount) text, \(toolCount) tool_use, stop=\(self.stopReason ?? "nil")")
        let reasoning = reasoningParts.isEmpty ? nil : reasoningParts.joined()
        return ClaudeResponse(
            content: contentBlocks,
            stopReason: stopReason,
            reasoningContent: reasoning
        )
    }

    // MARK: - Line Processing

    private func processLine(_ line: String) throws {
        guard line.hasPrefix("data: ") else { return }
        let payload = String(line.dropFirst(6))

        if payload == "[DONE]" {
            flushAll()
            return
        }

        guard let data = payload.data(using: .utf8) else { return }
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("OpenAI stream: non-dictionary JSON: \(payload.prefix(200))")
                return
            }
            obj = parsed
        } catch {
            logger.warning("OpenAI stream: JSON parse failed: \(error.localizedDescription) — \(payload.prefix(200))")
            return
        }

        // Check for error
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String
        {
            logger.error("OpenAI stream error: \(message)")
            throw ClaudeService.ClaudeServiceError.streamError(message)
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first
        else { return }

        // Finish reason
        if let reason = choice["finish_reason"] as? String {
            // Map OpenAI finish reasons to Anthropic equivalents
            stopReason = switch reason {
            case "tool_calls": "tool_use"
            case "stop": "end_turn"
            case "length": "max_tokens"
            default: reason
            }
        }

        guard let delta = choice["delta"] as? [String: Any] else { return }

        // Reasoning/thinking content (Moonshot non-standard field)
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            reasoningParts.append(reasoning)
        }

        // Text content
        if let content = delta["content"] as? String, !content.isEmpty {
            textParts.append(content)
            onEvent(.textDelta(content))
        }

        // Tool calls (streamed incrementally)
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let index = tc["index"] as? Int else { continue }

                // First chunk for this tool includes id and function name
                if let id = tc["id"] as? String,
                   let function = tc["function"] as? [String: Any],
                   let name = function["name"] as? String
                {
                    flushText()
                    activeToolCalls[index] = ToolCallAccumulator(
                        id: id,
                        name: name,
                        arguments: function["arguments"] as? String ?? ""
                    )
                    onEvent(.toolUseStart(id: id, name: name))
                } else if let function = tc["function"] as? [String: Any],
                          let args = function["arguments"] as? String
                {
                    // Subsequent chunks append to arguments
                    activeToolCalls[index]?.arguments.append(args)
                }
            }
        }
    }

    // MARK: - Flush

    private func flushText() {
        guard !textParts.isEmpty else { return }
        contentBlocks.append(.text(textParts.joined()))
        textParts = []
    }

    private func flushToolCalls() {
        let sorted = activeToolCalls.sorted { $0.key < $1.key }
        for (_, tc) in sorted {
            var input: [String: Any] = [:]
            if let data = tc.arguments.data(using: .utf8) {
                do {
                    if let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        input = parsed
                    }
                } catch {
                    logger.warning("Failed to parse tool args for \(tc.name): \(error.localizedDescription)")
                }
            }
            contentBlocks.append(.toolUse(id: tc.id, name: tc.name, input: input))
        }
        activeToolCalls.removeAll()
    }

    private func flushAll() {
        flushText()
        flushToolCalls()
    }
}
