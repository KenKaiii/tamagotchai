import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "codex-stream"
)

/// Parses SSE events from the OpenAI Codex `/responses` endpoint.
///
/// Codex uses a different event format than chat completions: events have an `event:` line
/// with dotted type names (e.g. `response.output_text.delta`) and a `data:` line with JSON.
@MainActor
final class CodexStreamParser {
    private let onEvent: @Sendable (StreamEvent) -> Void
    private var contentBlocks: [ContentBlock] = []
    private var stopReason: String?

    // Text accumulation
    private var textParts: [String] = []

    // Reasoning/thinking content accumulation
    private var reasoningParts: [String] = []

    // Tool call accumulation — keyed by "call_id|item_id"
    private var activeToolCalls: [String: ToolCallAccumulator] = [:]

    private struct ToolCallAccumulator {
        let id: String
        let name: String
        var arguments: String
    }

    init(onEvent: @escaping @Sendable (StreamEvent) -> Void) {
        self.onEvent = onEvent
    }

    func parse(bytes: URLSession.AsyncBytes) async throws {
        // Process each line individually. Each `data:` line contains complete JSON
        // with a `type` field, so we don't need to accumulate chunks.
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
        logger.info("Codex stream done — \(textCount) text, \(toolCount) tool_use, stop=\(self.stopReason ?? "nil")")
        let reasoning = reasoningParts.isEmpty ? nil : reasoningParts.joined()
        return ClaudeResponse(
            content: contentBlocks,
            stopReason: stopReason,
            reasoningContent: reasoning
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
                logger.warning("Codex stream: non-dictionary JSON: \(payload.prefix(200))")
                return
            }
            obj = parsed
        } catch {
            logger.warning("Codex stream: JSON parse failed: \(error.localizedDescription) — \(payload.prefix(200))")
            return
        }
        guard let type = obj["type"] as? String else { return }

        try processEvent(type: type, obj: obj)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func processEvent(type: String, obj: [String: Any]) throws {
        switch type {
        // --- Errors ---

        case "error":
            let msg = obj["message"] as? String ?? "Unknown Codex error"
            logger.error("Codex stream error: \(msg)")
            throw ClaudeService.ClaudeServiceError.streamError(msg)

        case "response.failed":
            let error = obj["error"] as? [String: Any]
            let msg = error?["message"] as? String ?? "Codex response failed"
            logger.error("Codex response failed: \(msg)")
            throw ClaudeService.ClaudeServiceError.streamError(msg)

        case "response.incomplete":
            let error = obj["error"] as? [String: Any]
            let reason = error?["message"] as? String ?? "Response incomplete"
            logger.warning("Codex response incomplete: \(reason)")

        // --- Text ---

        case "response.output_text.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                textParts.append(delta)
                onEvent(.textDelta(delta))
            }

        case "response.reasoning_summary_text.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                reasoningParts.append(delta)
            }

        // --- Tool calls ---

        case "response.output_item.added":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "function_call"
            else { return }

            flushText()

            let callId = item["call_id"] as? String ?? ""
            let itemId = item["id"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let key = "\(callId)|\(itemId)"

            activeToolCalls[key] = ToolCallAccumulator(
                id: key,
                name: name,
                arguments: item["arguments"] as? String ?? ""
            )
            onEvent(.toolUseStart(id: key, name: name))

        case "response.function_call_arguments.delta":
            guard let delta = obj["delta"] as? String,
                  let itemId = obj["item_id"] as? String
            else { return }

            for key in activeToolCalls.keys where key.hasSuffix("|\(itemId)") {
                activeToolCalls[key]?.arguments.append(delta)
                break
            }

        case "response.function_call_arguments.done":
            guard let itemId = obj["item_id"] as? String,
                  let argsStr = obj["arguments"] as? String
            else { return }

            for key in activeToolCalls.keys where key.hasSuffix("|\(itemId)") {
                activeToolCalls[key]?.arguments = argsStr
                break
            }

        case "response.output_item.done":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "function_call"
            else { return }

            let callId = item["call_id"] as? String ?? ""
            let itemId = item["id"] as? String ?? ""
            let key = "\(callId)|\(itemId)"

            if let tc = activeToolCalls.removeValue(forKey: key) {
                var input: [String: Any] = [:]
                if let data = tc.arguments.data(using: .utf8) {
                    do {
                        if let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            input = parsed
                        }
                    } catch {
                        logger.warning("Failed to parse Codex tool args for \(tc.name): \(error.localizedDescription)")
                    }
                }
                contentBlocks.append(.toolUse(id: tc.id, name: tc.name, input: input))
            }

        // --- Completion ---

        case "response.completed", "response.done":
            flushAll()
            // Extract status from response payload if available (more robust than content check)
            if let response = obj["response"] as? [String: Any],
               let status = response["status"] as? String
            {
                stopReason = switch status {
                case "completed":
                    contentBlocks.contains(where: { if case .toolUse = $0 { return true }
                        return false
                    })
                        ? "tool_use" : "end_turn"
                case "incomplete": "max_tokens"
                default: "end_turn"
                }
            } else {
                let hasToolCalls = contentBlocks.contains(where: { if case .toolUse = $0 { return true }
                    return false
                })
                stopReason = hasToolCalls ? "tool_use" : "end_turn"
            }

        // Informational events we don't need to act on
        case "response.created",
             "response.in_progress",
             "response.output_text.done",
             "response.content_part.added",
             "response.content_part.done",
             "response.reasoning_summary_text.done":
            break

        default:
            break
        }
    }

    // MARK: - Flush

    private func flushText() {
        guard !textParts.isEmpty else { return }
        contentBlocks.append(.text(textParts.joined()))
        textParts = []
    }

    private func flushToolCalls() {
        for (_, tc) in activeToolCalls {
            var input: [String: Any] = [:]
            if let data = tc.arguments.data(using: .utf8) {
                if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = parsed
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
