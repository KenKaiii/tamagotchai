import AppKit
import CoreGraphics
import Foundation
@testable import Tama
import Testing

/// End-to-end integration tests that drive the full pipeline:
///   user prompt → agent loop → tool call → image attached → vision model →
///   model response referencing the image.
///
/// Gated on `TAMA_RUN_VISION_TESTS` so normal test runs don't burn API tokens.
/// Credentials come from `~/.gg/auth.json` via `GGAuthBridge`.

/// Thread-safe event collector for the AgentLoop's `onEvent` callback. The
/// callback is `@Sendable` and may fire on background executors, so we can't
/// mutate a plain captured `var` under Swift 6 strict concurrency.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Suite(
    "Screenshot + AgentLoop (Live API)",
    .enabled(if: ProcessInfo.processInfo.environment["TAMA_RUN_VISION_TESTS"] != nil)
)
struct ScreenshotAgentLoopTests {
    // MARK: - Fake Screenshot Tool

    /// Tool that pretends to be `screenshot` but returns a synthetic solid-color
    /// image. Lets us verify end-to-end vision plumbing without needing real
    /// Screen Recording permission inside the test host.
    private struct FakeScreenshotTool: AgentTool {
        let name = "screenshot"
        let description = "Capture a screenshot of the user's screen and attach it for analysis."

        /// Solid color we ask the model to identify.
        static let targetHex = "FF6B00"
        static let targetColor = NSColor(
            red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x00 / 255.0, alpha: 1.0
        )

        var inputSchema: [String: Any] {
            ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
        }

        func execute(args _: [String: Any]) async throws -> ToolOutput {
            let pngData = Self.renderTargetPNG()
            return ToolOutput(
                text: "Screenshot captured (256×256, \(pngData.count) bytes).",
                images: [ToolImage(mediaType: "image/png", data: pngData)]
            )
        }

        static func renderTargetPNG() -> Data {
            let size = 256
            let ctx = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(targetColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            return rep.representation(using: .png, properties: [:])!
        }
    }

    // MARK: - Positive Case: Vision Model Sees Tool Image

    @Test("Moonshot Kimi K2.5: agent calls screenshot tool, model sees the image, answers about color")
    @MainActor
    func moonshotAgentLoopSeesScreenshot() async throws {
        try ensureCredential(for: .moonshot)
        let model = ModelRegistry.model(withId: "kimi-k2.5")!
        ProviderStore.shared.setSelectedModel(model)

        let registry = ToolRegistry(tools: [FakeScreenshotTool()])
        let loop = AgentLoop(workingDirectory: NSTemporaryDirectory(), registry: registry, maxTurns: 4)

        let userMsg: [String: Any] = [
            "role": "user",
            "content": "Please call the screenshot tool, then tell me what is the dominant color on my screen. "
                + "Reply with a single short sentence naming the color.",
        ]

        let collector = EventCollector()
        let conversation = try await loop.run(
            messages: [userMsg],
            systemPrompt: nil,
            maxTokens: 400,
            onEvent: { collector.record($0) }
        )

        // Verify the tool was actually invoked.
        let toolInvocations = collector.snapshot().compactMap { event -> String? in
            if case let .toolStart(name, _) = event { return name }
            return nil
        }
        #expect(toolInvocations.contains("screenshot"), "Agent should have invoked the screenshot tool")

        // Verify the final textual answer mentions orange or a close hex.
        let finalText = conversation.compactMap { msg -> String? in
            guard msg["role"] as? String == "assistant",
                  let blocks = msg["content"] as? [[String: Any]] else { return nil }
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            return texts.joined()
        }.joined(separator: " ").lowercased()

        // Accept any orange-family hex or the word "orange" — the model isn't a
        // color picker, we just want to confirm it *saw* the image.
        let hexRegex = try Regex("#?ff[67][0-9a-f]{3}")
        let mentionsHex = finalText.contains(hexRegex)
        let mentionsOrange = finalText.contains("orange")
        #expect(
            mentionsHex || mentionsOrange,
            "Expected the assistant's final text to mention orange or an orange hex, got: \(finalText)"
        )
    }

    // MARK: - Negative Case: Non-Vision Model Discards Image

    /// When the active model doesn't support vision (Xiaomi/MiniMax), the
    /// AgentLoop must silently drop the image bytes and forward only the text.
    /// The model will then respond based on text alone — so we verify it does
    /// NOT get tripped up by the image and that the tool loop still completes.
    @Test("MiniMax M2.7 Highspeed: image bytes are dropped, text result still delivered")
    @MainActor
    func miniMaxDropsImageButContinues() async throws {
        try ensureCredential(for: .minimax)
        let model = ModelRegistry.model(withId: "MiniMax-M2.7-highspeed")!
        #expect(model.supportsVision == false)
        ProviderStore.shared.setSelectedModel(model)

        let registry = ToolRegistry(tools: [FakeScreenshotTool()])
        let loop = AgentLoop(workingDirectory: NSTemporaryDirectory(), registry: registry, maxTurns: 4)

        let userMsg: [String: Any] = [
            "role": "user",
            "content": "Call the screenshot tool once. When it returns, report the byte size "
                + "it mentioned in its text result. Reply with one short sentence.",
        ]

        let collector = EventCollector()
        let conversation = try await loop.run(
            messages: [userMsg],
            systemPrompt: nil,
            maxTokens: 400,
            onEvent: { collector.record($0) }
        )

        let sawTool = collector.snapshot().contains { event in
            if case let .toolStart(name, _) = event, name == "screenshot" { return true }
            return false
        }
        #expect(sawTool, "Agent should have invoked the screenshot tool")

        // Ensure no turn contains a tool_result with an image block — AgentLoop
        // must have stripped it because the model doesn't support vision.
        for msg in conversation {
            guard msg["role"] as? String == "user",
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            for block in blocks where (block["type"] as? String) == "tool_result" {
                if let arr = block["content"] as? [[String: Any]] {
                    let hasImage = arr.contains { ($0["type"] as? String) == "image" }
                    #expect(hasImage == false, "Non-vision model should never receive an image block")
                }
            }
        }

        // And the assistant should still produce *some* reply (it may or may
        // not be accurate — we just verify the pipeline completed).
        let finalText = conversation.compactMap { msg -> String? in
            guard msg["role"] as? String == "assistant",
                  let blocks = msg["content"] as? [[String: Any]] else { return nil }
            return blocks.compactMap { ($0["text"] as? String) }.joined()
        }.joined(separator: " ")
        #expect(!finalText.isEmpty, "Expected assistant to reply in the final turn")
    }

    // MARK: - Helpers

    @MainActor
    private func ensureCredential(for provider: AIProvider) throws {
        if ProviderStore.shared.hasCredentials(for: provider) { return }
        guard let token = GGAuthBridge.accessToken(for: provider) else {
            throw VisionIntegrationError.missingCredentials(provider)
        }
        let cred: ProviderCredential
        if provider.usesOAuth {
            cred = ProviderCredential(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                accountId: GGAuthBridge.accountId(for: provider) ?? ""
            )
        } else {
            cred = ProviderCredential.apiKey(token)
        }
        ProviderStore.shared.setCredential(cred, for: provider)
    }
}

// MARK: - Errors

private enum VisionIntegrationError: LocalizedError {
    case missingCredentials(AIProvider)
    var errorDescription: String? {
        switch self {
        case let .missingCredentials(provider):
            "No credentials for \(provider.displayName)"
        }
    }
}
