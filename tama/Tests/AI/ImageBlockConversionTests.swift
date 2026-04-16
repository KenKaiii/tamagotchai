import Foundation
@testable import Tama
import Testing

/// Verifies that image blocks inside `tool_result.content` arrays are
/// translated correctly into each provider's native vision format.
@Suite("ImageBlockConversion")
struct ImageBlockConversionTests {
    // Minimal 1-pixel red PNG payload (base64). We don't decode it, only verify
    // that the converter forwards the bytes verbatim into a data URL.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    private static func anthropicImage() -> [String: Any] {
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/png",
                "data": pngBase64,
            ],
        ]
    }

    private static func toolResult(id: String, parts: [[String: Any]]) -> [String: Any] {
        [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": parts,
                ],
            ],
        ]
    }

    // MARK: - OpenAI Chat Completions (Moonshot / Xiaomi)

    @Test("OpenAI chat: text+image tool_result emits tool message + user image_url message")
    @MainActor
    func openAIChatTextPlusImage() {
        let msg = Self.toolResult(id: "toolu_abc", parts: [
            ["type": "text", "text": "Screenshot saved (1920x1080, 12345 bytes)"],
            Self.anthropicImage(),
        ])

        let converted = ClaudeService.shared.convertMessageToOpenAI(msg)

        // First emitted message should be the tool result text.
        #expect(converted.count == 2)
        let toolMsg = converted[0]
        #expect(toolMsg["role"] as? String == "tool")
        #expect(toolMsg["tool_call_id"] as? String == "toolu_abc")
        #expect((toolMsg["content"] as? String)?.contains("Screenshot saved") == true)

        // Second message: user with image_url content carrying the data URL.
        let userMsg = converted[1]
        #expect(userMsg["role"] as? String == "user")
        let userContent = userMsg["content"] as? [[String: Any]]
        #expect(userContent != nil)
        let imageBlock = userContent?.first { ($0["type"] as? String) == "image_url" }
        #expect(imageBlock != nil)
        let urlDict = imageBlock?["image_url"] as? [String: Any]
        let dataURL = urlDict?["url"] as? String
        #expect(dataURL?.hasPrefix("data:image/png;base64,") == true)
        #expect(dataURL?.contains(Self.pngBase64) == true)
    }

    @Test("OpenAI chat: text-only tool_result emits a single tool message, no user follow-up")
    @MainActor
    func openAIChatTextOnly() {
        let msg = Self.toolResult(id: "toolu_xyz", parts: [
            ["type": "text", "text": "plain text result"],
        ])
        let converted = ClaudeService.shared.convertMessageToOpenAI(msg)
        #expect(converted.count == 1)
        #expect(converted[0]["role"] as? String == "tool")
        #expect(converted[0]["content"] as? String == "plain text result")
    }

    @Test("OpenAI chat: legacy string content tool_result still works")
    @MainActor
    func openAIChatLegacyStringContent() {
        let msg: [String: Any] = [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": "toolu_legacy",
                    "content": "legacy string output",
                ],
            ],
        ]
        let converted = ClaudeService.shared.convertMessageToOpenAI(msg)
        #expect(converted.count == 1)
        #expect(converted[0]["content"] as? String == "legacy string output")
    }

    // MARK: - Codex /responses (OpenAI ChatGPT Plus)

    @Test("Codex: text+image tool_result emits function_call_output + user input_image item")
    func codexTextPlusImage() {
        let msg = Self.toolResult(id: "toolu_codex", parts: [
            ["type": "text", "text": "Screenshot saved"],
            Self.anthropicImage(),
        ])

        let converted = CodexRequestBuilder.convertMessages([msg])

        #expect(converted.count == 2)
        let outputItem = converted[0]
        #expect(outputItem["type"] as? String == "function_call_output")
        #expect((outputItem["output"] as? String)?.contains("Screenshot saved") == true)
        // call_id must be remapped to fc_ prefix.
        let callId = outputItem["call_id"] as? String
        #expect(callId?.hasPrefix("fc_") == true)

        let userItem = converted[1]
        #expect(userItem["role"] as? String == "user")
        let userContent = userItem["content"] as? [[String: Any]]
        #expect(userContent != nil)
        let imageBlock = userContent?.first { ($0["type"] as? String) == "input_image" }
        #expect(imageBlock != nil)
        let dataURL = imageBlock?["image_url"] as? String
        #expect(dataURL?.hasPrefix("data:image/png;base64,") == true)
        #expect(dataURL?.contains(Self.pngBase64) == true)
    }

    @Test("Codex: text-only tool_result emits a single function_call_output, no follow-up")
    func codexTextOnly() {
        let msg = Self.toolResult(id: "toolu_codex2", parts: [
            ["type": "text", "text": "plain output"],
        ])
        let converted = CodexRequestBuilder.convertMessages([msg])
        #expect(converted.count == 1)
        #expect(converted[0]["type"] as? String == "function_call_output")
        #expect(converted[0]["output"] as? String == "plain output")
    }

    @Test("Codex: legacy string content tool_result still works")
    func codexLegacyStringContent() {
        let msg: [String: Any] = [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": "toolu_codex_legacy",
                    "content": "legacy string output",
                ],
            ],
        ]
        let converted = CodexRequestBuilder.convertMessages([msg])
        #expect(converted.count == 1)
        #expect(converted[0]["output"] as? String == "legacy string output")
    }

    // MARK: - Anthropic (MiniMax pass-through)

    /// MiniMax's `/anthropic` endpoint takes Anthropic-native messages
    /// verbatim, so the AgentLoop's image block is shipped as-is. We don't
    /// have a converter to test directly, but we lock in the on-the-wire
    /// shape of the AgentLoop output here so future refactors can't silently
    /// break MiniMax compatibility.
    @Test("Anthropic native: tool_result content is an array with text + image blocks")
    func anthropicNativeShape() {
        let parts: [[String: Any]] = [
            ["type": "text", "text": "hello"],
            Self.anthropicImage(),
        ]
        let block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": "toolu_native",
            "content": parts,
        ]
        let content = block["content"] as? [[String: Any]]
        #expect(content?.count == 2)
        #expect(content?[0]["type"] as? String == "text")
        let imgBlock = content?[1]
        #expect(imgBlock?["type"] as? String == "image")
        let source = imgBlock?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == Self.pngBase64)
    }
}
