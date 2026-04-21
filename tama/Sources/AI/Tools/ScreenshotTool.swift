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
    Capture the user's screen and attach the image to your context so you can literally see what \
    they're looking at. Saves to ~/Documents/Tama/Screenshots/.

    ## When to use this tool (call it proactively, don't wait to be asked)

    - The user mentions anything visible: "this error", "this window", "what I'm looking at", \
      "this page", "my screen".
    - "Where's X?" / "how do I X?" / "I can't find X" — capture first, then use `point` to show them.
    - UI bugs, layout issues, rendering problems.
    - Reading text that's on-screen (error dialogs, form fields, menu labels).
    - Before giving step-by-step GUI instructions — see what's actually open.

    ## Pair with `point`

    When the user asks WHERE something is or HOW to click through something, the full pattern is \
    screenshot → analyze → `point` at the target while narrating aloud. Don't just describe a \
    location in words; guide their eyes with the virtual cursor.

    ## When NOT to use

    - Pure knowledge questions ("what year did X happen?").
    - When you already took a screenshot this turn and the screen hasn't changed.
    - If the active model can't see images the tool returns an error — relay it verbatim and stop.
    """

    /// Cap output width at 3072px — matches OpenAI's Responses API
    /// `detail: "original"` tier (up to 6000px / 10.24M pixels), which is what
    /// OpenAI's own `openai-cua-sample-app` reference uses for GPT-5.4 computer
    /// use. OpenAI's release notes specifically credit `original`/`high` detail
    /// with "strong gains in localization ability, image understanding, and
    /// click accuracy" over the default compressed tier. At 3072 we ship the
    /// full native retina capture of a 14" MBP (3024×1964) with no downscale,
    /// so a 22pt menu-bar icon occupies ~44 pixels — double what the 2048 cap
    /// gave the vision encoder.
    private static let maxWidth = 3072
    /// Fixed JPEG quality, retained for callers that still opt into JPEG. The
    /// call path below now defaults to PNG (lossless) to match OpenAI's own
    /// `openai-cua-sample-app` reference. JPEG-92 stays near-lossless for small
    /// icons but PNG removes the last compression artifacts the vision encoder
    /// can see on 22px menu-bar glyphs.
    private static let jpegQuality = 92

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
                    "description": "0-based display index. Omit this argument (uses main display). " +
                        "Only pass a non-zero value if the user has explicitly confirmed they have " +
                        "multiple displays AND they've told you the target is on a specific one. " +
                        "Do NOT call this tool multiple times to 'check all displays' — the user has " +
                        "ONE display by default.",
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
        // Format and quality are intentionally NOT exposed to the model. PNG
        // (lossless) matches OpenAI's own CUA sample app — they ship PNG +
        // `detail: "original"` for GPT-5.4 computer use. Earlier we let the
        // model pick format/quality; it started choosing JPEG-80 and small UI
        // icons lost the edge detail the vision encoder needed, producing
        // multi-centimetre cursor drift.
        let format = "png"
        let quality = Self.jpegQuality

        logger.info("Capturing screenshot: display=\(displayIndex), format=\(format), quality=\(quality)")

        // Enumerate displays via ScreenCaptureKit. First call may trigger the
        // Screen Recording prompt if the preflight cache hasn't been refreshed.
        //
        // This call also doubles as a real permission probe. `CGPreflightScreenCaptureAccess`
        // is cached within the process lifetime and is known to lie in several
        // cases — it can stay `true` after the user revokes access in System
        // Settings, return `false` on macOS Sequoia even when actually granted,
        // and go stale after code-signing identity changes (e.g. a Sparkle
        // update). If preflight said we were granted but SCShareableContent
        // actually fails here, that's our signal that the TCC entry is stale;
        // surface a permission error with the recovery path instead of a vague
        // "capture failed".
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            // If preflight said granted but the probe failed, the TCC state is
            // stale — nudge the user to toggle permission in Settings.
            if CGPreflightScreenCaptureAccess() {
                logger
                    .error(
                        "Stale Screen Recording permission detected — preflight says granted but probe failed"
                    )
                await MainActor.run {
                    PermissionsChecker.shared.openScreenRecordingSettings()
                }
                throw ScreenshotToolError.permissionDenied
            }
            throw ScreenshotToolError.captureFailed(error.localizedDescription)
        }

        // Probe: if we were told we had access but there are no capturable
        // windows with titles at all, TCC is lying. Real-world projects
        // (Ice, Thaw, omi) use this exact signal to detect stale grants.
        let hasReadableWindow = content.windows.contains { window in
            window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && window.title != nil
        }
        if !hasReadableWindow, !content.windows.isEmpty {
            logger.error("Screen capture permission appears stale — no readable window titles")
            await MainActor.run {
                PermissionsChecker.shared.openScreenRecordingSettings()
            }
            throw ScreenshotToolError.permissionDenied
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
        // Capture at NATIVE pixel dimensions, not point dimensions.
        //
        // `SCDisplay.width` / `.height` return the display's size in POINTS on
        // recent macOS (e.g. 1512×982 on a 14" MBP), not native pixels. If we
        // use those directly, `SCStreamConfiguration` downsamples the capture by
        // the display's backing scale factor — so a retina screen lands in the
        // image at 1512×982 instead of its real 3024×1964, halving the
        // resolution the vision model sees. That directly degrades pointing
        // accuracy for small UI targets (menu-bar icons, dock items) because a
        // 22pt icon only occupies ~22 image pixels instead of ~44.
        //
        // Scale by the matching NSScreen's `backingScaleFactor` so we capture at
        // full retina resolution. The existing `downscaleIfNeeded` below caps
        // the transmitted image at `maxWidth` (2560px) — so payload size stays
        // bounded while the intermediate capture preserves all native detail.
        let scale = Self.backingScaleFactor(for: display)
        config.width = Int((Double(display.width) * scale).rounded())
        config.height = Int((Double(display.height) * scale).rounded())
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
        let nativeWidth = cgImage.width
        let nativeHeight = cgImage.height
        let summary = "Screenshot captured: \(width)x\(height) " +
            "(native \(nativeWidth)x\(nativeHeight)), \(imageData.count) bytes"
        logger.info("\(summary, privacy: .public), saved to \(filePath, privacy: .public)")

        // Include both processed (what the model sees) and native (what the
        // screen actually is) dimensions so the agent can reason about scale
        // when estimating small-target coordinates. The 0–1000 integer grid
        // is viewport-independent — same coords work regardless of display
        // resolution — matching the pattern used by Gemini Computer Use,
        // GLM-4.6V, UI-TARS, and AutoGLM.
        let scaleNote = nativeWidth == width
            ? ""
            : " — downscaled from \(nativeWidth)×\(nativeHeight) native pixels"
        let text = "Screenshot saved to \(filePath) " +
            "(\(width)×\(height)\(scaleNote), \(imageData.count) bytes). " +
            "Coords for `point`, `highlight`, `arrow`, `countdown` use a 0–1000 integer grid " +
            "over this image: (0,0) = top-left, (1000,1000) = bottom-right. Output plain " +
            "integers like x=523, y=210 — NOT fractions like 0.523."
        return ToolOutput(
            text: text,
            images: [ToolImage(mediaType: mediaType, data: imageData)]
        )
    }

    // MARK: - Image Processing

    /// Returns the `NSScreen.backingScaleFactor` for the `NSScreen` whose
    /// CoreGraphics display ID matches this `SCDisplay`'s `displayID`.
    /// Falls back to the main screen's scale, then to 2.0 (typical retina),
    /// then to 1.0 if no screens are enumerable. Called on a background
    /// thread during screenshot execution; reads `NSScreen.screens` which
    /// is safe to access from any thread.
    private static func backingScaleFactor(for display: SCDisplay) -> Double {
        let targetID = display.displayID
        if let screen = NSScreen.screens.first(where: { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return num?.uint32Value == targetID
        }) {
            return Double(screen.backingScaleFactor)
        }
        if let main = NSScreen.main {
            return Double(main.backingScaleFactor)
        }
        return 2.0
    }

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

    /// Maximum number of screenshots kept on disk. Older captures are deleted
    /// after each write so the folder can't grow unbounded across long sessions.
    /// Ten is enough for the user to scrub back through a recent call without
    /// hoarding hundreds of ~450KB files.
    private static let maxRetainedScreenshots = 10

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

        pruneOldScreenshots(in: dir, keepLatest: Self.maxRetainedScreenshots)
        return filePath
    }

    /// Delete all but the `keepLatest` most-recent `screenshot_*` files in
    /// `dir`. Sort key is creation date (stable even if the ISO8601-in-filename
    /// sort order ever drifts). Errors are logged and swallowed — cleanup must
    /// never fail the screenshot tool itself.
    private func pruneOldScreenshots(in dir: String, keepLatest: Int) {
        let url = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger
                .warning(
                    "Screenshot prune: failed to list \(dir, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return
        }

        // Only consider files we wrote — screenshot_*.{jpg,png}. Guards against
        // accidentally deleting anything else that ends up in the folder.
        let screenshots = contents.filter { file in
            let name = file.lastPathComponent
            guard name.hasPrefix("screenshot_") else { return false }
            let ext = file.pathExtension.lowercased()
            return ext == "jpg" || ext == "jpeg" || ext == "png"
        }

        guard screenshots.count > keepLatest else { return }

        // Newest first by creation date; fall back to filename (ISO-8601
        // prefix is lexically sortable) when creationDate is missing.
        let sorted = screenshots.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let lDate, let rDate { return lDate > rDate }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }

        let toDelete = sorted.dropFirst(keepLatest)
        for file in toDelete {
            do {
                try fm.removeItem(at: file)
            } catch {
                logger
                    .warning(
                        "Screenshot prune: failed to delete \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
            }
        }
        logger.info("Screenshot prune: kept \(keepLatest), deleted \(toDelete.count)")
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
            return base + "Add a vision-capable model (like Kimi K2.6 or GPT-5.4) in AI Settings, "
                + "then switch to it."
        }
        let list = alternatives.joined(separator: ", ")
        return base + "Switch to a vision-capable model in AI Settings — you have: \(list)."
    }
}
