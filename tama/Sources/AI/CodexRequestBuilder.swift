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
    private static func convertMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var input: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }

            // User messages with string content
            if role == "user", let content = msg["content"] as? String {
                input.append([
                    "role": "user",
                    "content": [["type": "input_text", "text": content]],
                ])
                continue
            }

            // User messages with array content (may contain tool_result blocks)
            if role == "user", let blocks = msg["content"] as? [[String: Any]] {
                for block in blocks {
                    guard let type = block["type"] as? String else { continue }

                    if type == "text", let text = block["text"] as? String {
                        input.append([
                            "role": "user",
                            "content": [["type": "input_text", "text": text]],
                        ])
                    } else if type == "tool_result",
                              let toolUseId = block["tool_use_id"] as? String,
                              let content = block["content"] as? String
                    {
                        // Extract just the call_id part (before the pipe)
                        let callId = toolUseId.contains("|")
                            ? String(toolUseId.split(separator: "|").first!)
                            : toolUseId

                        input.append([
                            "type": "function_call_output",
                            "call_id": remapId(callId),
                            "output": content,
                        ])
                    }
                }
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
