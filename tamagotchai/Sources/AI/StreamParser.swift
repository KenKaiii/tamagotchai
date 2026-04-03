import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "stream"
)

/// Parses SSE events from the Anthropic streaming API, tracking text and
/// tool_use content blocks.
@MainActor
final class StreamParser {
    private let onEvent: @Sendable (StreamEvent) -> Void
    private var currentEvent = ""
    private var contentBlocks: [ContentBlock] = []
    private var stopReason: String?

    // Client tool-use accumulation
    private var toolId: String?
    private var toolName: String?
    private var toolJsonParts: [String] = []
    private var isServerTool = false

    // Text accumulation
    private var textParts: [String] = []

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
        logger
            .info(
                // swiftformat:disable:next redundantSelf
                "Stream done — \(textCount) text, \(toolCount) tool_use, stop=\(self.stopReason ?? "nil")"
            )
        return ClaudeResponse(
            content: contentBlocks,
            stopReason: stopReason
        )
    }

    // MARK: - Line Processing

    private func processLine(_ line: String) throws {
        if line.hasPrefix("event: ") {
            currentEvent = String(line.dropFirst(7))
            return
        }

        guard line.hasPrefix("data: ") else { return }
        let json = String(line.dropFirst(6))
        guard let data = json.data(using: .utf8) else { return }
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // swiftformat:disable:next redundantSelf
                logger.warning("Non-object JSON on event \(self.currentEvent): \(json.prefix(200))")
                return
            }
            obj = parsed
        } catch {
            // swiftformat:disable:next redundantSelf
            logger.warning("Malformed JSON on event \(self.currentEvent): \(error.localizedDescription)")
            return
        }

        switch currentEvent {
        case "content_block_start":
            handleBlockStart(obj)
        case "content_block_delta":
            handleBlockDelta(obj)
        case "content_block_stop":
            handleBlockStop()
        case "message_delta":
            handleMessageDelta(obj)
        case "message_stop":
            // Final signal — flush any remaining state
            flushText()
        case "error":
            try handleError(obj)
        default:
            if !currentEvent.isEmpty {
                // swiftformat:disable:next redundantSelf
                logger.warning("Unrecognized stream event type: \(self.currentEvent)")
            }
        }
    }

    private func handleBlockStart(_ obj: [String: Any]) {
        guard let block = obj["content_block"] as? [String: Any],
              let type = block["type"] as? String
        else { return }
        logger.debug("content_block_start: type=\(type)")

        if type == "tool_use" {
            flushText()
            toolId = block["id"] as? String
            toolName = block["name"] as? String
            toolJsonParts = []
            isServerTool = false
            if let id = toolId, let name = toolName {
                onEvent(.toolUseStart(id: id, name: name))
            }
        } else if type == "server_tool_use" {
            flushText()
            toolId = block["id"] as? String
            toolName = block["name"] as? String
            toolJsonParts = []
            isServerTool = true
            if let id = toolId, let name = toolName {
                onEvent(.toolUseStart(id: id, name: name))
            }
        } else if type == "web_search_tool_result" {
            let useId = block["tool_use_id"] as? String ?? ""
            let content = block["content"] as? [[String: Any]] ?? []
            // Check for error in the content array
            if let first = content.first,
               first["type"] as? String == "web_search_tool_result_error",
               let errorCode = first["error_code"] as? String
            {
                contentBlocks.append(
                    .serverToolResultError(
                        toolUseId: useId,
                        errorCode: errorCode
                    )
                )
            } else {
                contentBlocks.append(
                    .serverToolResult(
                        toolUseId: useId,
                        content: content
                    )
                )
            }
        } else if type == "text" {
            textParts = []
        }
    }

    private func handleBlockDelta(_ obj: [String: Any]) {
        guard let delta = obj["delta"] as? [String: Any],
              let type = delta["type"] as? String
        else { return }

        if type == "text_delta",
           let text = delta["text"] as? String
        {
            textParts.append(text)
            onEvent(.textDelta(text))
        } else if type == "input_json_delta",
                  let partial = delta["partial_json"] as? String
        {
            toolJsonParts.append(partial)
        }
    }

    private func handleBlockStop() {
        if let id = toolId {
            let fullJson = toolJsonParts.joined()
            var input: [String: Any] = [:]
            if let jsonData = fullJson.data(using: .utf8) {
                do {
                    if let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        input = parsed
                    } else {
                        let preview = String(fullJson.prefix(200))
                        let name = toolName ?? "?"
                        logger.warning(
                            "Tool input JSON is not an object for \(name): \(preview)"
                        )
                    }
                } catch {
                    let preview = String(fullJson.prefix(200))
                    let name = toolName ?? "?"
                    let desc = error.localizedDescription
                    logger.warning(
                        "Failed to parse tool input JSON for \(name): \(desc) — raw: \(preview)"
                    )
                }
            }
            if isServerTool {
                contentBlocks.append(
                    .serverToolUse(
                        id: id,
                        name: toolName ?? "",
                        input: input
                    )
                )
            } else {
                contentBlocks.append(
                    .toolUse(
                        id: id,
                        name: toolName ?? "",
                        input: input
                    )
                )
            }
            toolId = nil
            toolName = nil
            toolJsonParts = []
            isServerTool = false
        } else {
            flushText()
        }
    }

    private func handleMessageDelta(_ obj: [String: Any]) {
        if let delta = obj["delta"] as? [String: Any],
           let reason = delta["stop_reason"] as? String
        {
            stopReason = reason
        }
    }

    private func handleError(_ obj: [String: Any]) throws {
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String
        {
            logger.error("Stream error from API: \(message)")
            throw ClaudeService.ClaudeServiceError.streamError(message)
        }
    }

    private func flushText() {
        guard !textParts.isEmpty else { return }
        contentBlocks.append(.text(textParts.joined()))
        textParts = []
    }
}
