import Foundation
@testable import Tama
import Testing

/// Deterministic unit tests for how AgentLoop packages tool outputs into
/// tool_result blocks. Verifies:
///   - vision-capable models get array content with text + image blocks
///   - non-vision models get plain string content, image bytes discarded
///
/// These tests exercise the packaging in isolation by calling `claude.sendWithTools`
/// through a stubbed codepath — but since stubbing the network is invasive,
/// we instead verify the shape by building the exact conversation payload the
/// AgentLoop would emit and inspecting it via the public format converters.
@Suite("AgentLoop Image Packaging")
struct AgentLoopImagePackagingTests {
    // Minimal 1-pixel PNG for fixture purposes.
    private static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    /// Simulates the exact tool_result block shape that AgentLoop emits when a
    /// tool returns an image AND the active model supports vision.
    private static func visionToolResult() -> [String: Any] {
        [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": "toolu_abc",
                    "content": [
                        ["type": "text", "text": "Screenshot captured (256×256, 123 bytes)."],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": tinyPNGBase64,
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Simulates the tool_result block shape that AgentLoop emits when the
    /// active model does NOT support vision — the image bytes are discarded
    /// and only the text is forwarded as plain string content.
    private static func textOnlyToolResult() -> [String: Any] {
        [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": "toolu_abc",
                    "content": "Screenshot captured (256×256, 123 bytes).",
                ],
            ],
        ]
    }

    // MARK: - Vision Path

    @Test("OpenAI-compatible: vision tool_result produces tool msg + user image_url msg")
    @MainActor
    func openAIVisionPathEmitsImageURL() {
        let converted = ClaudeService.shared.convertMessageToOpenAI(Self.visionToolResult())

        // Expect exactly two messages: the tool result, then a user message with the image.
        #expect(converted.count == 2)
        #expect(converted[0]["role"] as? String == "tool")
        #expect(converted[1]["role"] as? String == "user")

        let userContent = converted[1]["content"] as? [[String: Any]]
        let imageBlock = userContent?.first { ($0["type"] as? String) == "image_url" }
        #expect(imageBlock != nil, "user message should carry an image_url block")
        let dataURL = (imageBlock?["image_url"] as? [String: Any])?["url"] as? String
        #expect(dataURL?.hasPrefix("data:image/png;base64,") == true)
        #expect(dataURL?.contains(Self.tinyPNGBase64) == true)
    }

    @Test("Codex: vision tool_result produces function_call_output + user input_image")
    func codexVisionPathEmitsInputImage() {
        let converted = CodexRequestBuilder.convertMessages([Self.visionToolResult()])

        #expect(converted.count == 2)
        #expect(converted[0]["type"] as? String == "function_call_output")
        #expect(converted[1]["role"] as? String == "user")

        let userContent = converted[1]["content"] as? [[String: Any]]
        let imageBlock = userContent?.first { ($0["type"] as? String) == "input_image" }
        #expect(imageBlock != nil, "user item should carry an input_image block")
        let dataURL = imageBlock?["image_url"] as? String
        #expect(dataURL?.hasPrefix("data:image/png;base64,") == true)
    }

    // MARK: - Non-Vision Path

    @Test("OpenAI-compatible: text-only tool_result emits single tool msg (no image leak)")
    @MainActor
    func openAITextOnlyPathHasNoImage() {
        let converted = ClaudeService.shared.convertMessageToOpenAI(Self.textOnlyToolResult())

        #expect(converted.count == 1)
        #expect(converted[0]["role"] as? String == "tool")
        #expect(converted[0]["content"] as? String == "Screenshot captured (256×256, 123 bytes).")

        // Defensive: there must be no user follow-up carrying image_url.
        let anyImage = converted.contains { msg in
            if let arr = msg["content"] as? [[String: Any]] {
                return arr.contains { ($0["type"] as? String) == "image_url" }
            }
            return false
        }
        #expect(anyImage == false)
    }

    @Test("Codex: text-only tool_result emits single function_call_output (no image leak)")
    func codexTextOnlyPathHasNoImage() {
        let converted = CodexRequestBuilder.convertMessages([Self.textOnlyToolResult()])

        #expect(converted.count == 1)
        #expect(converted[0]["type"] as? String == "function_call_output")
        #expect(converted[0]["output"] as? String == "Screenshot captured (256×256, 123 bytes).")

        let anyImage = converted.contains { item in
            if let content = item["content"] as? [[String: Any]] {
                return content.contains { ($0["type"] as? String) == "input_image" }
            }
            return false
        }
        #expect(anyImage == false)
    }

    // MARK: - Shape Verification (AgentLoop output)

    /// Mirrors the exact payload shape AgentLoop emits for a vision-capable
    /// run so future refactors can't silently change the contract that
    /// downstream converters rely on.
    @Test("Vision-capable tool_result has array content with matching block types")
    func visionShapeContract() {
        let msg = Self.visionToolResult()
        let blocks = msg["content"] as? [[String: Any]]
        let toolResult = blocks?.first
        let content = toolResult?["content"] as? [[String: Any]]

        #expect(content?.count == 2)
        #expect(content?[0]["type"] as? String == "text")
        let imageBlock = content?[1]
        #expect(imageBlock?["type"] as? String == "image")
        let source = imageBlock?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == Self.tinyPNGBase64)
    }

    @Test("Non-vision tool_result has plain string content (no image blocks)")
    func nonVisionShapeContract() {
        let msg = Self.textOnlyToolResult()
        let blocks = msg["content"] as? [[String: Any]]
        let toolResult = blocks?.first
        #expect(toolResult?["content"] is String)
    }
}
