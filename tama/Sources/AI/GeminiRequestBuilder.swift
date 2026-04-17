import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "gemini-request"
)

/// Builds HTTP requests for Google's Cloud Code Assist streaming endpoint
/// (`POST v1internal:streamGenerateContent?alt=sse`).
///
/// Wraps a Gemini `generateContent` request in the Cloud Code Assist envelope:
/// `{ project, model, request: { contents, systemInstruction, generationConfig, tools }, userAgent, requestId }`
enum GeminiRequestBuilder {
    /// Build a URLRequest for the Cloud Code Assist streaming endpoint.
    static func buildRequest( // swiftlint:disable:this function_parameter_count
        token: String,
        projectId: String,
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
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("google-cloud-sdk vscode_cloudshelleditor/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("gl-node/22.17.0", forHTTPHeaderField: "X-Goog-Api-Client")
        let clientMetadata = #"{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}"#
        request.setValue(clientMetadata, forHTTPHeaderField: "Client-Metadata")
        request.timeoutInterval = 120

        let contents = convertMessages(messages)

        var innerRequest: [String: Any] = [
            "contents": contents,
        ]

        if let systemPrompt, !systemPrompt.isEmpty {
            innerRequest["systemInstruction"] = [
                "parts": [["text": systemPrompt]],
            ] as [String: Any]
        }

        // Generation config — disable thinking by default to avoid latency.
        var generationConfig: [String: Any] = [:]
        if model.supportsThinking {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0] as [String: Any]
        }
        if !generationConfig.isEmpty {
            innerRequest["generationConfig"] = generationConfig
        }

        if let tools, !tools.isEmpty {
            innerRequest["tools"] = convertTools(tools)
        }

        let requestId = "tama-\(Int(Date().timeIntervalSince1970 * 1000))-"
            + String(UUID().uuidString.prefix(9).lowercased())

        let body: [String: Any] = [
            "project": projectId,
            "model": model.id,
            "request": innerRequest,
            "userAgent": "tama",
            "requestId": requestId,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Message Conversion

    /// Convert Anthropic-format messages to Gemini `Content[]` array.
    static func convertMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var contents: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }

            // User messages with string content
            if role == "user", let content = msg["content"] as? String {
                contents.append([
                    "role": "user",
                    "parts": [["text": content]],
                ])
                continue
            }

            // User messages with array content (may contain text, image, and/or tool_result blocks).
            if role == "user", let blocks = msg["content"] as? [[String: Any]] {
                var pendingMixed: [[String: Any]] = []

                func flushPending() {
                    guard !pendingMixed.isEmpty else { return }
                    contents.append(["role": "user", "parts": pendingMixed])
                    pendingMixed = []
                }

                for block in blocks {
                    guard let type = block["type"] as? String else { continue }

                    if type == "text", let text = block["text"] as? String {
                        pendingMixed.append(["text": text])
                    } else if type == "image",
                              let source = block["source"] as? [String: Any],
                              let mediaType = source["media_type"] as? String,
                              let data = source["data"] as? String
                    {
                        pendingMixed.append([
                            "inlineData": [
                                "mimeType": mediaType,
                                "data": data,
                            ] as [String: Any],
                        ])
                    } else if type == "tool_result",
                              let toolUseId = block["tool_use_id"] as? String
                    {
                        flushPending()
                        appendToolResult(
                            toolUseId: toolUseId,
                            content: block["content"],
                            into: &contents
                        )
                    }
                }
                flushPending()
                continue
            }

            // Assistant messages with string content
            if role == "assistant", let content = msg["content"] as? String {
                contents.append([
                    "role": "model",
                    "parts": [["text": content]],
                ])
                continue
            }

            // Assistant messages with array content (text + tool_use blocks)
            if role == "assistant", let blocks = msg["content"] as? [[String: Any]] {
                var parts: [[String: Any]] = []
                for block in blocks {
                    guard let type = block["type"] as? String else { continue }

                    if type == "text", let text = block["text"] as? String, !text.isEmpty {
                        parts.append(["text": text])
                    } else if type == "tool_use",
                              let id = block["id"] as? String,
                              let name = block["name"] as? String,
                              let inputDict = block["input"]
                    {
                        let args = (inputDict as? [String: Any]) ?? [:]
                        parts.append([
                            "functionCall": [
                                "id": id,
                                "name": name,
                                "args": args,
                            ] as [String: Any],
                        ])
                    }
                }
                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": parts])
                }
                continue
            }
        }

        return contents
    }

    /// Append a tool_result block to `contents` as a `functionResponse` part.
    /// Per Cloud Code Assist rules, consecutive function responses merge into
    /// a single user turn.
    private static func appendToolResult(
        toolUseId: String,
        content: Any?,
        into contents: inout [[String: Any]]
    ) {
        // Collect text + images.
        var textParts: [String] = []
        var imageParts: [[String: Any]] = []

        if let str = content as? String {
            textParts.append(str)
        } else if let parts = content as? [[String: Any]] {
            for part in parts {
                guard let type = part["type"] as? String else { continue }
                if type == "text", let text = part["text"] as? String {
                    textParts.append(text)
                } else if type == "image",
                          let source = part["source"] as? [String: Any],
                          let mediaType = source["media_type"] as? String,
                          let data = source["data"] as? String
                {
                    imageParts.append([
                        "inlineData": [
                            "mimeType": mediaType,
                            "data": data,
                        ] as [String: Any],
                    ])
                }
            }
        }

        let output = textParts.isEmpty
            ? (imageParts.isEmpty ? "" : "(see attached image)")
            : textParts.joined(separator: "\n")

        // Use the tool call's own name if encoded in the id ("name::id") — but
        // in our case the id is opaque. Cloud Code Assist accepts a bare name
        // field; it's used for display only. We pass the toolUseId as the name
        // fallback.
        let functionResponse: [String: Any] = [
            "functionResponse": [
                "id": toolUseId,
                "name": toolUseId,
                "response": ["output": output] as [String: Any],
            ] as [String: Any],
        ]

        // Merge into last user turn if that turn already holds functionResponse parts.
        if var last = contents.last,
           (last["role"] as? String) == "user",
           var parts = last["parts"] as? [[String: Any]],
           parts.contains(where: { $0["functionResponse"] != nil })
        {
            parts.append(functionResponse)
            last["parts"] = parts
            contents[contents.count - 1] = last
        } else {
            contents.append([
                "role": "user",
                "parts": [functionResponse],
            ])
        }

        // For images, add a separate user turn (matches pi-mono's Gemini <3 path).
        if !imageParts.isEmpty {
            var imageTurnParts: [[String: Any]] = [["text": "Tool result image:"]]
            imageTurnParts.append(contentsOf: imageParts)
            contents.append([
                "role": "user",
                "parts": imageTurnParts,
            ])
        }
    }

    // MARK: - Tool Conversion

    /// Convert Anthropic tool definitions to Gemini `functionDeclarations` format.
    private static func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        let declarations: [[String: Any]] = tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            var decl: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String {
                decl["description"] = desc
            }
            if let schema = tool["input_schema"] as? [String: Any] {
                decl["parametersJsonSchema"] = schema
            }
            return decl
        }
        return [["functionDeclarations": declarations]]
    }
}
