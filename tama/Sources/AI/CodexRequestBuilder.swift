import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "codex-request"
)

/// Builds HTTP requests for the OpenAI Codex `/responses` API.
///
/// The Codex format differs significantly from OpenAI chat completions:
/// - Uses `instructions` for system prompt (not a message)
/// - Uses `input` array with Codex-specific types instead of `messages`
/// - Tool IDs must use `fc_` prefix instead of `toolu_`
enum CodexRequestBuilder {
    /// Build a URLRequest for the Codex streaming responses endpoint.
    static func buildRequest( // swiftlint:disable:this function_parameter_count
        token: String,
        accountId: String,
        model: ModelInfo,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        systemPrompt: String?
    ) throws -> URLRequest {
        let url = URL(string: model.provider.baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("tama", forHTTPHeaderField: "originator")
        request.setValue("tama/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let input = convertMessages(messages)

        var body: [String: Any] = [
            "model": model.id,
            "store": false,
            "stream": true,
            "instructions": systemPrompt as Any,
            "input": input,
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "include": ["reasoning.encrypted_content"],
            // Disable thinking to avoid latency — see ModelRegistry.usesCustomThinkingParam
            "reasoning": ["effort": "none", "summary": "auto"],
        ]

        if let tools, !tools.isEmpty {
            body["tools"] = convertTools(tools)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Message Conversion

    /// Convert Anthropic-format messages to Codex input array.
    /// Internal so the test suite can exercise format conversion directly.
    ///
    /// Images in the MOST-RECENT image-bearing message are attached with
    /// `detail: "original"` (the top vision tier, up to 6000px / 10.24M pixels).
    /// This is what OpenAI's own `openai-cua-sample-app` reference ships for
    /// GPT-5.4 computer use, and what their release notes credit with "strong
    /// gains in localization ability, image understanding, and click accuracy."
    /// Older screenshots in history fall back to `detail: "auto"` so we don't
    /// pay the high-tier processing cost on every conversation turn.
    static func convertMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        let latestImageIdx = indexOfLastMessageWithImage(messages)

        for (idx, msg) in messages.enumerated() {
            guard let role = msg["role"] as? String else { continue }
            let detail = idx == latestImageIdx ? "original" : "auto"

            // User messages with string content
            if role == "user", let content = msg["content"] as? String {
                input.append([
                    "role": "user",
                    "content": [["type": "input_text", "text": content]],
                ])
                continue
            }

            // User messages with array content (may contain text, image, and/or
            // tool_result blocks). Adjacent text+image blocks merge into one
            // user input item so vision works in a single conversation turn.
            if role == "user", let blocks = msg["content"] as? [[String: Any]] {
                var pendingMixed: [[String: Any]] = []

                func flushPending() {
                    guard !pendingMixed.isEmpty else { return }
                    input.append(["role": "user", "content": pendingMixed])
                    pendingMixed = []
                }

                for block in blocks {
                    guard let type = block["type"] as? String else { continue }

                    if type == "text", let text = block["text"] as? String {
                        pendingMixed.append(["type": "input_text", "text": text])
                    } else if type == "image",
                              let source = block["source"] as? [String: Any],
                              let mediaType = source["media_type"] as? String,
                              let data = source["data"] as? String
                    {
                        pendingMixed.append([
                            "type": "input_image",
                            "image_url": "data:\(mediaType);base64,\(data)",
                            "detail": detail,
                        ])
                    } else if type == "tool_result",
                              let toolUseId = block["tool_use_id"] as? String
                    {
                        flushPending()
                        input.append(contentsOf: convertToolResult(
                            toolUseId: toolUseId,
                            content: block["content"],
                            imageDetail: detail
                        ))
                    }
                }
                flushPending()
                continue
            }

            // Assistant messages with string content
            if role == "assistant", let content = msg["content"] as? String {
                input.append([
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": content, "annotations": [] as [Any]]],
                    "status": "completed",
                ])
                continue
            }

            // Assistant messages with array content (text + tool_use blocks)
            if role == "assistant", let blocks = msg["content"] as? [[String: Any]] {
                for block in blocks {
                    guard let type = block["type"] as? String else { continue }

                    if type == "text", let text = block["text"] as? String {
                        input.append([
                            "type": "message",
                            "role": "assistant",
                            "content": [["type": "output_text", "text": text, "annotations": [] as [Any]]],
                            "status": "completed",
                        ])
                    } else if type == "tool_use",
                              let id = block["id"] as? String,
                              let name = block["name"] as? String,
                              let inputDict = block["input"]
                    {
                        let argsData = (try? JSONSerialization.data(withJSONObject: inputDict)) ?? Data()
                        let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"

                        // Split "callId|itemId" format from codex parser
                        let parts = id.split(separator: "|", maxSplits: 1)
                        let callId = parts.count == 2 ? String(parts[0]) : id
                        let itemId = parts.count == 2 ? String(parts[1]) : id

                        input.append([
                            "type": "function_call",
                            "id": remapId(itemId),
                            "call_id": remapId(callId),
                            "name": name,
                            "arguments": argsStr,
                        ])
                    }
                }
                continue
            }
        }

        return input
    }

    /// Returns the index of the last message whose `content` contains at
    /// least one `image` or `tool_result`-with-image block, or `-1` if none.
    /// Used to decide which screenshots are the "current" ones that deserve
    /// high-detail vision processing vs. stale history that can ride at auto.
    private static func indexOfLastMessageWithImage(_ messages: [[String: Any]]) -> Int {
        for idx in stride(from: messages.count - 1, through: 0, by: -1) {
            guard let blocks = messages[idx]["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                let type = block["type"] as? String
                if type == "image" { return idx }
                if type == "tool_result",
                   let inner = block["content"] as? [[String: Any]],
                   inner.contains(where: { $0["type"] as? String == "image" })
                {
                    return idx
                }
            }
        }
        return -1
    }

    /// Convert a tool_result block's content to one or more Codex input items:
    /// a `function_call_output` with the text portion, plus an optional
    /// `role:"user"` message carrying any image blocks as `input_image` data
    /// URLs. `imageDetail` controls the vision tier — `"high"` for the current
    /// screenshot, `"auto"` for stale ones still in history.
    private static func convertToolResult(
        toolUseId: String,
        content: Any?,
        imageDetail: String = "auto"
    ) -> [[String: Any]] {
        // Extract just the call_id part (before the pipe).
        let callId = toolUseId.contains("|")
            ? String(toolUseId.split(separator: "|").first!)
            : toolUseId
        let mappedCallId = remapId(callId)

        // Simple string content: single function_call_output, no images.
        if let str = content as? String {
            return [[
                "type": "function_call_output",
                "call_id": mappedCallId,
                "output": str,
            ]]
        }

        guard let parts = content as? [[String: Any]] else {
            return []
        }

        var textParts: [String] = []
        var imageItems: [[String: Any]] = []

        for part in parts {
            guard let type = part["type"] as? String else { continue }
            if type == "text", let text = part["text"] as? String {
                textParts.append(text)
            } else if type == "image",
                      let source = part["source"] as? [String: Any],
                      let mediaType = source["media_type"] as? String,
                      let data = source["data"] as? String
            {
                imageItems.append([
                    "type": "input_image",
                    "image_url": "data:\(mediaType);base64,\(data)",
                    "detail": imageDetail,
                ])
            }
        }

        var result: [[String: Any]] = [[
            "type": "function_call_output",
            "call_id": mappedCallId,
            "output": textParts.isEmpty ? "" : textParts.joined(separator: "\n"),
        ]]

        if !imageItems.isEmpty {
            var userContent: [[String: Any]] = [[
                "type": "input_text",
                "text": "Screenshot attached from the previous tool call.",
            ]]
            userContent.append(contentsOf: imageItems)
            result.append([
                "role": "user",
                "content": userContent,
            ])
        }

        return result
    }

    // MARK: - Tool Conversion

    /// Convert Anthropic tool definitions to Codex function format.
    private static func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            guard let name = tool["name"] as? String else { return nil }

            var function: [String: Any] = [
                "type": "function",
                "name": name,
                "strict": NSNull(),
            ]
            if let desc = tool["description"] as? String {
                function["description"] = desc
            }
            if let schema = tool["input_schema"] as? [String: Any] {
                function["parameters"] = schema
            }
            return function
        }
    }

    // MARK: - ID Remapping

    /// Remap tool IDs to use the `fc_` prefix required by Codex.
    private static func remapId(_ id: String) -> String {
        if id.hasPrefix("fc_") || id.hasPrefix("fc-") { return id }
        let stripped = id.hasPrefix("toolu_") ? String(id.dropFirst(6)) : id
        return "fc_\(stripped)"
    }
}
