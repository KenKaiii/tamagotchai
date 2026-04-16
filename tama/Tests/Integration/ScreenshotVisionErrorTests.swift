import Foundation
@testable import Tama
import Testing

/// Live integration tests that verify the vision-not-supported error path
/// end-to-end: user invokes the screenshot tool while a non-vision model is
/// active, the tool fails fast, and the error text propagates to the model
/// which relays it to the user. Gated on `TAMA_RUN_VISION_TESTS`.
@Suite(
    "Screenshot Vision Error Feedback (Live API)",
    .enabled(if: ProcessInfo.processInfo.environment["TAMA_RUN_VISION_TESTS"] != nil)
)
struct ScreenshotVisionErrorTests {
    @Test("MiniMax (non-vision): screenshot tool fails fast, model relays the error to the user")
    @MainActor
    func nonVisionModelSurfacesActionableError() async throws {
        try ensureCredential(for: .minimax)
        let model = ModelRegistry.model(withId: "MiniMax-M2.7-highspeed")!
        #expect(model.supportsVision == false)
        ProviderStore.shared.setSelectedModel(model)

        // Use the REAL ScreenshotTool so we exercise the new vision guard.
        let registry = ToolRegistry(tools: [ScreenshotTool()])
        let loop = AgentLoop(
            workingDirectory: NSTemporaryDirectory(),
            registry: registry,
            maxTurns: 4
        )

        let userMsg: [String: Any] = [
            "role": "user",
            "content": "Take a screenshot of my screen and describe what you see.",
        ]

        let conversation = try await loop.run(
            messages: [userMsg],
            systemPrompt: nil,
            maxTokens: 400,
            onEvent: { _ in }
        )

        // 1. The tool_result must carry the specific, actionable error text.
        let toolResultsText = conversation.flatMap { msg -> [String] in
            guard msg["role"] as? String == "user",
                  let blocks = msg["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { block -> String? in
                guard block["type"] as? String == "tool_result" else { return nil }
                return block["content"] as? String
            }
        }.joined(separator: "\n")

        #expect(toolResultsText.contains("can't see images"), "Tool error should name the capability gap")
        #expect(toolResultsText.contains("AI Settings"), "Tool error should point users to AI Settings")

        // 2. The final assistant text should relay the error to the user rather
        //    than retrying the tool or hallucinating a description.
        let finalText = conversation.compactMap { msg -> String? in
            guard msg["role"] as? String == "assistant",
                  let blocks = msg["content"] as? [[String: Any]] else { return nil }
            return blocks.compactMap { ($0["text"] as? String) }.joined()
        }.joined(separator: "\n").lowercased()

        #expect(!finalText.isEmpty, "Assistant must reply, not go silent")
        // The model should mention the capability issue or point the user to
        // switch models. We accept any of these surface forms.
        let surfacesTheError =
            finalText.contains("can't see") || finalText.contains("cannot see")
                || finalText.contains("doesn't support") || finalText.contains("does not support")
                || finalText.contains("switch") || finalText.contains("vision")
                || finalText.contains("ai settings") || finalText.contains("kimi") || finalText.contains("gpt-5")
        #expect(
            surfacesTheError,
            "Assistant should tell the user about the vision gap or suggest switching. Got: \(finalText)"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func ensureCredential(for provider: AIProvider) throws {
        if ProviderStore.shared.hasCredentials(for: provider) { return }
        guard let token = GGAuthBridge.accessToken(for: provider) else {
            struct NoCreds: Error {}
            throw NoCreds()
        }
        ProviderStore.shared.setCredential(ProviderCredential.apiKey(token), for: provider)
    }
}
