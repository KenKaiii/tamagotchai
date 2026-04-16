import AppKit
import CoreGraphics
import Foundation
@testable import Tama
import Testing

/// Live API tests that verify each vision-capable model can actually *see* an
/// attached image. Gated on the `TAMA_RUN_VISION_TESTS` environment variable
/// so CI (and ordinary test runs) don't burn API tokens.
///
/// Run locally with:
///   TAMA_RUN_VISION_TESTS=1 xcodebuild -scheme Tama -destination 'platform=macOS' test
///
/// Credentials are read from `~/.gg/auth.json` via `GGAuthBridge`, with env
/// var fallback `TAMA_<PROVIDER>_KEY`.
@Suite(
    "Vision Providers (Live API)",
    .enabled(if: ProcessInfo.processInfo.environment["TAMA_RUN_VISION_TESTS"] != nil)
)
struct VisionProviderTests {
    // The synthetic image is a 256×256 solid block of #FF6B00 (a vivid
    // red-orange). Every vision model should easily identify the dominant
    // color in plain prose.
    private static let targetHex = "FF6B00"
    private static let targetColor = NSColor(
        red: 0xFF / 255.0,
        green: 0x6B / 255.0,
        blue: 0x00 / 255.0,
        alpha: 1.0
    )

    // MARK: - Per-Model Tests

    @Test("Moonshot Kimi K2.5 sees the attached image")
    @MainActor
    func moonshotKimiVision() async throws {
        try await runVisionTest(modelId: "kimi-k2.5")
    }

    @Test("OpenAI GPT-5.4 sees the attached image")
    @MainActor
    func openAIGpt54Vision() async throws {
        try await runVisionTest(modelId: "gpt-5.4")
    }

    @Test("OpenAI GPT-5.4 Mini sees the attached image")
    @MainActor
    func openAIGpt54MiniVision() async throws {
        try await runVisionTest(modelId: "gpt-5.4-mini")
    }

    @Test("OpenAI GPT-5.3 Codex sees the attached image")
    @MainActor
    func openAIGpt53CodexVision() async throws {
        try await runVisionTest(modelId: "gpt-5.3-codex")
    }

    // MARK: - Driver

    @MainActor
    private func runVisionTest(modelId: String) async throws {
        guard let model = ModelRegistry.model(withId: modelId) else {
            Issue.record("Unknown model id \(modelId)")
            return
        }
        guard model.supportsVision else {
            Issue.record("Model \(modelId) is not flagged as supportsVision = true")
            return
        }

        // Ensure credentials are loaded into ProviderStore for this provider.
        try ensureCredential(for: model.provider)
        ProviderStore.shared.setSelectedModel(model)

        // Build a single-turn user message: text prompt + base64 image.
        let pngData = renderTargetPNG()
        let userMessage: [String: Any] = [
            "role": "user",
            "content": [
                [
                    "type": "text",
                    "text":
                        "What is the dominant color in this image? Reply with just the hex code (e.g. #RRGGBB) or a short color name.",
                ],
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": pngData.base64EncodedString(),
                    ],
                ],
            ],
        ]

        let response = try await ClaudeService.shared.sendWithTools(
            messages: [userMessage],
            tools: [],
            systemPrompt: nil,
            maxTokens: 200,
            onEvent: { _ in }
        )

        let text = response.textContent.lowercased()
        // The image is solid #FF6B00. We accept any of:
        //   - a hex code in the orange family (#ff6xxx / #ff7xxx)
        //   - the words "orange", "red-orange", "red orange"
        // This is intentionally loose: the goal is to verify the model *saw*
        // the image at all, not to grade its color-naming precision.
        let hexRegex = try Regex("#?ff[67][0-9a-f]{3}")
        let mentionsHex = text.contains(hexRegex)
        let mentionsColor = text.contains("orange") || text.contains("red-orange") || text.contains("red orange")
        #expect(
            mentionsHex || mentionsColor,
            "Expected response to mention an orange hex or 'orange', got: \(response.textContent)"
        )
    }

    // MARK: - Synthetic PNG

    /// Render a 256×256 PNG of the target color. Deterministic and tiny
    /// (~250 bytes) so we don't burn tokens on input image size.
    private func renderTargetPNG() -> Data {
        let size = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!

        context.setFillColor(Self.targetColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let image = context.makeImage()!
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Credential Loading

    @MainActor
    private func ensureCredential(for provider: AIProvider) throws {
        if ProviderStore.shared.hasCredentials(for: provider) {
            return
        }
        guard let token = GGAuthBridge.accessToken(for: provider) else {
            throw VisionTestError.missingCredentials(provider)
        }

        let credential: ProviderCredential
        if provider.usesOAuth {
            // Codex requires accountId in the credential.
            let accountId = GGAuthBridge.accountId(for: provider) ?? ""
            credential = ProviderCredential(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                accountId: accountId
            )
        } else {
            credential = ProviderCredential.apiKey(token)
        }
        ProviderStore.shared.setCredential(credential, for: provider)
    }
}

// MARK: - Errors

private enum VisionTestError: LocalizedError {
    case missingCredentials(AIProvider)

    var errorDescription: String? {
        switch self {
        case let .missingCredentials(provider):
            "No credentials found for \(provider.displayName) in ~/.gg/auth.json or env var TAMA_\(provider.rawValue.uppercased())_KEY"
        }
    }
}
