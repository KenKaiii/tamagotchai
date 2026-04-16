import AppKit
import CoreGraphics
import Foundation
@testable import Tama
import Testing

/// Exercises the real `ScreenshotTool` end-to-end — actual `SCScreenshotManager`
/// capture, real disk write, real image bytes forwarded to a vision model.
///
/// Requires `TAMA_RUN_VISION_TESTS=1` and valid Moonshot credentials.
/// Also requires Screen Recording permission granted to the XCTest host
/// bundle — each macOS bundle has its own TCC entry, so the app being
/// granted doesn't automatically cover the test runner. When permission
/// isn't granted the test is skipped at runtime with a clear log.
@Suite(
    "Real ScreenshotTool End-to-End (Live API)",
    .enabled(if: ProcessInfo.processInfo.environment["TAMA_RUN_VISION_TESTS"] != nil)
)
struct RealScreenshotTests {
    @Test("real SCScreenshotManager capture → attached to Moonshot → model responds about it")
    @MainActor
    func realScreenshotThroughAgent() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("⚠️ Screen Recording not granted to XCTest host — skipping.")
            return
        }

        // Configure Moonshot as the active provider using local gg auth.
        try ensureCredential(for: .moonshot)
        let model = ModelRegistry.model(withId: "kimi-k2.5")!
        #expect(model.supportsVision)
        ProviderStore.shared.setSelectedModel(model)

        // Use the REAL ScreenshotTool — no fakes.
        let registry = ToolRegistry(tools: [ScreenshotTool()])
        let loop = AgentLoop(
            workingDirectory: NSTemporaryDirectory(),
            registry: registry,
            maxTurns: 4
        )

        let userMsg: [String: Any] = [
            "role": "user",
            "content":
                "Take a screenshot of my screen with the screenshot tool, then describe what you see "
                    + "in one short sentence. Keep it under 25 words.",
        ]

        let conversation = try await loop.run(
            messages: [userMsg],
            systemPrompt: nil,
            maxTokens: 400,
            onEvent: { _ in }
        )

        // Collect every assistant text reply across turns.
        let finalText = conversation.compactMap { msg -> String? in
            guard msg["role"] as? String == "assistant",
                  let blocks = msg["content"] as? [[String: Any]] else { return nil }
            return blocks.compactMap { ($0["text"] as? String) }.joined()
        }.joined(separator: "\n")

        // Looking for any sign of visual analysis — should not be empty, and
        // should not be a generic "I don't see any image" brush-off.
        #expect(!finalText.isEmpty, "Expected assistant to produce a description")
        let lowered = finalText.lowercased()
        let refusalPhrases = [
            "don't see any image",
            "didn't receive any image",
            "no image was attached",
            "i cannot see",
            "i can't see",
        ]
        for phrase in refusalPhrases {
            #expect(
                !lowered.contains(phrase),
                "Model appears to have missed the image attachment. Reply was: \(finalText)"
            )
        }

        // Confirm a screenshot file was actually written to disk.
        let screenshotsDir = PromptPanelController.screenshotsDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: screenshotsDir)
        let hasScreenshot = files.contains { $0.hasPrefix("screenshot_") }
        #expect(hasScreenshot, "Expected at least one screenshot file in \(screenshotsDir)")

        print("📸 Final assistant reply: \(finalText)")
    }

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
