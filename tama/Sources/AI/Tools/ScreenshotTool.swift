import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.screenshot"
)

/// Agent tool that captures a full-screen screenshot and attaches it to the
/// model's context (for vision-capable models). The image is also written to
/// `~/Documents/Tama/Screenshots/` for the user to inspect.
final class ScreenshotTool: AgentTool {
    let name = "screenshot"
    let description = """
    Capture a screenshot of the user's screen and attach it for analysis. The image is saved to \
    ~/Documents/Tama/Screenshots/ and sent to the model so you can visually see what's on the screen. \
    Use this when the user asks about what they're looking at, to diagnose UI issues, read text from \
    windows, or verify visual state.
    """

    /// Cap output width at 1920px to keep base64 payload small and token cost sane.
    private static let maxWidth = 1920
    /// JPEG default quality (0-100).
    private static let defaultJPEGQuality = 85

    /// Returns the currently selected model. Injectable for tests so vision
    /// enforcement can be exercised deterministically without touching the
    /// live ProviderStore state.
    private let currentModelProvider: @MainActor @Sendable () -> ModelInfo

    /// Returns vision-capable alternatives the user has configured. Injectable
    /// so tests can seed a deterministic list without depending on ProviderStore.
    private let visionAlternativesProvider: @MainActor @Sendable () -> [String]

    init(
        currentModelProvider: @MainActor @Sendable @escaping () -> ModelInfo = { ProviderStore.shared.selectedModel },
        visionAlternativesProvider: @MainActor @Sendable @escaping () -> [String] = ScreenshotTool
            .defaultVisionAlternatives
    ) {
        self.currentModelProvider = currentModelProvider
        self.visionAlternativesProvider = visionAlternativesProvider
    }

    /// Default source of vision-capable model names — only models the user has
    /// credentials for. Runs on the MainActor because ProviderStore is.
    @MainActor
    static func defaultVisionAlternatives() -> [String] {
        ModelRegistry.availableModels()
            .filter(\.supportsVision)
            .map(\.name)
    }

    // MARK: - Input Schema

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "display": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "0-based display index (default: main display).",
                ],
                "format": [
                    "type": "string",
                    "enum": ["png", "jpeg"],
                    "description": "Image format. JPEG (default) is ~10x smaller than PNG.",
                ],
                "quality": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "description": "JPEG quality 1-100 (default: 85). Ignored for PNG.",
                ],
            ],
            "required": [] as [String],
        ]
    }

    // MARK: - Execution

    func execute(args: [String: Any]) async throws -> ToolOutput {
        // Fail fast if the active model can't see images. Capturing pixels and
        // round-tripping them to a text-only backend wastes tokens and leaves
        // the user confused. This mirrors the `AppError` pattern — we surface
        // a clear, actionable message naming the current model and listing
        // vision-capable alternatives the user has access to.
        let current = await MainActor.run { self.currentModelProvider() }
        if !current.supportsVision {
            let alternatives = await MainActor.run { self.visionAlternativesProvider() }
            logger
                .error(
                    "Screenshot blocked — current model '\(current.name, privacy: .public)' lacks vision support"
                )
            throw ScreenshotToolError.visionNotSupported(
                currentModelName: current.name,
                alternatives: alternatives
            )
        }

        // Pre-flight permission check. If not granted, actively request access
        // (triggers the TCC system dialog the first time) and open System
        // Settings so the user can actually toggle Tama on. Without these side
        // effects the voice agent just tells the user "can't use that" with no
        // way forward. After the user grants access, the app must restart for
        // TCC to take effect — we say so explicitly in the error message.
        if !CGPreflightScreenCaptureAccess() {
            logger.error("Screen Recording permission not granted — prompting user")
            await MainActor.run {
                _ = PermissionsChecker.shared.requestScreenRecording()
                PermissionsChecker.shared.openScreenRecordingSettings()
            }
            throw ScreenshotToolError.permissionDenied
        }

        let displayIndex = args["display"] as? Int ?? 0
        let format = (args["format"] as? String)?.lowercased() ?? "jpeg"
        let quality = max(1, min(100, args["quality"] as? Int ?? Self.defaultJPEGQuality))

        guard format == "jpeg" || format == "png" else {
            throw ScreenshotToolError.captureFailed("Unsupported format: \(format)")
        }

        logger.info("Capturing screenshot: display=\(displayIndex), format=\(format), quality=\(quality)")

        // Enumerate displays via ScreenCaptureKit. First call may trigger the
        // Screen Recording prompt if the preflight cache hasn't been refreshed.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotToolError.captureFailed(error.localizedDescription)
        }

        guard !content.displays.isEmpty else {
            throw ScreenshotToolError.noDisplay
        }
        guard displayIndex >= 0, displayIndex < content.displays.count else {
            throw ScreenshotToolError.noDisplay
        }
        let display = content.displays[displayIndex]

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Use the display's native pixel dimensions (already retina-aware on
        // SCDisplay). We downscale below if it exceeds maxWidth.
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.captureResolution = .best

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotToolError.captureFailed(error.localizedDescription)
        }

        let downscaled = downscaleIfNeeded(cgImage)
        let imageData: Data
        let mediaType: String
        let fileExt: String
        if format == "png" {
            guard let data = encodePNG(downscaled) else {
                throw ScreenshotToolError.encodeFailed
            }
            imageData = data
            mediaType = "image/png"
            fileExt = "png"
        } else {
            guard let data = encodeJPEG(downscaled, quality: quality) else {
                throw ScreenshotToolError.encodeFailed
            }
            imageData = data
            mediaType = "image/jpeg"
            fileExt = "jpg"
        }

        let filePath = await writeToDisk(imageData, fileExt: fileExt)

        let width = downscaled.width
        let height = downscaled.height
        logger
            .info(
                "Screenshot captured: \(width)x\(height), \(imageData.count) bytes, saved to \(filePath, privacy: .public)"
            )

        let text = "Screenshot saved to \(filePath) (\(width)×\(height), \(imageData.count) bytes)"
        return ToolOutput(
            text: text,
            images: [ToolImage(mediaType: mediaType, data: imageData)]
        )
    }

    // MARK: - Image Processing

    /// Downscale so width <= maxWidth, preserving aspect ratio. Returns the
    /// original image if it already fits.
    private func downscaleIfNeeded(_ image: CGImage) -> CGImage {
        guard image.width > Self.maxWidth else { return image }

        let scale = Double(Self.maxWidth) / Double(image.width)
        let newWidth = Self.maxWidth
        let newHeight = max(1, Int((Double(image.height) * scale).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.warning("Downscale CGContext creation failed; using original image")
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    private func encodePNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func encodeJPEG(_ image: CGImage, quality: Int) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        let factor = max(0.0, min(1.0, Double(quality) / 100.0))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: factor])
    }

    // MARK: - File I/O

    @MainActor
    private func writeToDisk(_ data: Data, fileExt: String) -> String {
        let dir = PromptPanelController.screenshotsDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        )
        let sanitized = timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let filename = "screenshot_\(sanitized).\(fileExt)"
        let filePath = (dir as NSString).appendingPathComponent(filename)

        do {
            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            logger.error("Failed to write screenshot to disk: \(error.localizedDescription, privacy: .public)")
        }
        return filePath
    }
}

// MARK: - Errors

enum ScreenshotToolError: LocalizedError {
    case permissionDenied
    case noDisplay
    case captureFailed(String)
    case encodeFailed
    /// The currently selected model can't process images. Carries the current
    /// model's display name plus a list of vision-capable alternatives the
    /// user already has credentials for (may be empty if none configured).
    case visionNotSupported(currentModelName: String, alternatives: [String])

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is not granted. "
                + "Enable it in System Settings → Privacy & Security → Screen Recording, then restart Tama."
        case .noDisplay:
            "No display available to capture."
        case let .captureFailed(reason):
            "Screenshot capture failed: \(reason)"
        case .encodeFailed:
            "Failed to encode screenshot."
        case let .visionNotSupported(currentModelName, alternatives):
            Self.visionNotSupportedMessage(
                currentModelName: currentModelName,
                alternatives: alternatives
            )
        }
    }

    private static func visionNotSupportedMessage(
        currentModelName: String,
        alternatives: [String]
    ) -> String {
        let base = "\(currentModelName) can't see images. "
        if alternatives.isEmpty {
            return base + "Add a vision-capable model (like Kimi K2.5 or GPT-5.4) in AI Settings, "
                + "then switch to it."
        }
        let list = alternatives.joined(separator: ", ")
        return base + "Switch to a vision-capable model in AI Settings — you have: \(list)."
    }
}
