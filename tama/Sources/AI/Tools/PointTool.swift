import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.point"
)

/// Agent tool that moves a virtual (click-through) cursor to a spot on the
/// user's screen for tutor-mode pointing. The user's real cursor is untouched.
///
/// Pair with `screenshot`: take a capture, identify the target, then call
/// `point` with normalized 0-1 coordinates (top-left origin).
struct PointTool: AgentTool, @unchecked Sendable {
    let name = "point"
    let description = """
    Show the user WHERE something is on their screen by floating an orange virtual cursor over it. \
    Their real cursor is untouched — this is tutor mode, not remote control. Pair it with \
    narration: SAY the answer, POINT at it.

    ## When to use this tool (call it proactively)

    Any time the user is asking about something on their screen, especially "where", "how do I", \
    "show me", "find", "I can't see", "walk me through", "what do I click". The user is at their \
    computer — a visual pointer is almost always more useful than a text description of a location.

    Typical triggers:
    - "where's the [thing]?" → screenshot → point
    - "how do I [action]?" when the answer involves clicking something → screenshot → point at the first step
    - "I can't find [thing]" → screenshot → point
    - "show me how to [do thing in app]" → screenshot → point
    - "what's this?" / "what does this button do?" → screenshot → point at the thing in question
    - "walk me through [task]" → screenshot → point at the first control, then narrate next steps

    ## Workflow

    1. If you don't already know the layout from a recent screenshot, call `screenshot` first.
    2. Identify the target pixel region on the image.
    3. Call `point` with x,y as fractions of the image's width/height (top-left = 0,0).
    4. Narrate out loud what you're pointing at ("right there, top-left corner — the File menu"). \
       The cursor is silent; your words carry the explanation.
    5. For multi-step guides, point at ONE thing at a time. After the user does it (or says \
       they see it), take a new screenshot and point at the next step.

    ## When NOT to use this tool

    - Pure information questions with no on-screen target ("what's the capital of France?").
    - Actions you're performing on the user's behalf via `bash`, `write`, `edit`, etc. — those \
      don't need pointing.
    - When you haven't seen the screen and can't guess the target — take a `screenshot` first.
    - When the answer is literally just text (e.g. "press Cmd+Space") — say the shortcut.

    ## Coordinates — precision matters, especially for small targets

    x and y are normalized fractions in [0, 1] with (0, 0) = top-left, (1, 1) = bottom-right. \
    Match the `display` index to the screenshot you analyzed.

    Vision models have roughly ±2–5% positional error. For TARGETS WIDER THAN ~5% of the screen \
    that's fine. For smaller targets (menu-bar icons, toolbar buttons, tabs) be deliberate:

    1. **Anchor to landmarks**: estimate the target's position relative to known edges/corners, \
       not just "looks about here". E.g. "the icon is 3 icons left of the clock, and the clock is \
       at the far right at y≈0.015". Compute the x from that.
    2. **Count items in rows**: for menu bars, toolbars, tab strips, count positions from an edge. \
       "6th icon from the right in a 10-icon menu bar on a 1512pt-wide screen = x ≈ 1 - (5.5/10)×0.2".
    3. **macOS menu bar gotcha**: on Sonoma/Sequoia, Wi-Fi, Bluetooth, Sound, and Battery live \
       *inside* Control Center (the toggles icon) by default — they are NOT standalone menu-bar \
       icons unless the user unpinned them. If unsure whether an icon exists standalone, don't \
       guess; point at Control Center and tell the user to open it.
    4. **Don't hallucinate icons** you can't clearly see in the screenshot. If the user asked about \
       "the wifi icon" but you see Control Center instead, say so and point at Control Center.

    ## If the user says you're off, correct it

    After pointing, the cursor stays visible ~8s. If the user says "not quite", "more left", \
    "that's the wrong one", etc. — take a FRESH `screenshot` (the virtual cursor is captured in \
    subsequent shots), see where it actually landed, and call `point` again with a corrected \
    position. Never just guess an adjustment without re-checking visually.

    ## Multi-step walkthroughs ("walk me through X")

    Sequential `point` calls smoothly animate the cursor from its current position to the next \
    target — it does NOT flash off and reappear. This makes "click File, then Open Recent, then \
    your document" feel like a continuous guided path. The rhythm is:

    1. Take a `screenshot`. Identify the full path in your head.
    2. Call `point` at step 1. Say out loud what they should click.
    3. **Wait for the user to actually click** — they'll say "got it", "done", "ok", or ask "now \
       what?". Don't fire all points at once; the user can't keep up and the cursor races past.
    4. Once acknowledged, take another `screenshot` (the UI has changed), identify step 2 on the \
       NEW screen, then call `point` at step 2. Repeat.

    Rules:
    - **One cursor at a time.** Never call `point` twice in the same turn expecting both to be \
      visible — the second replaces the first.
    - **Fresh screenshot per step.** After the user clicks, menus open / views change; last turn's \
      screenshot is stale. Re-capture before estimating the next coordinate.
    - **Keep each `label` to 1–3 words** so adjacent steps don't feel wordy.
    - For a **path preview** (show the whole route at once without waiting for clicks), you can \
      fire `point` calls back-to-back — the cursor will animate through them — but add a \
      `hold_seconds` of ~4 on each step so the user sees each landmark briefly. Use this sparingly; \
      the step-by-step pattern is more useful.

    ## Labels

    The `label` is a tiny pill caption next to the cursor. Keep it to 1–3 words \
    (~20 characters max). It's a visual tag ("File menu", "Export", "Search"), not an \
    explanation — your voice/text carries the explanation. If you're tempted to write a \
    sentence, cut it down to the noun and put the rest in your reply.
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "x": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Horizontal position as fraction of screen width. " +
                        "0 = left edge, 1 = right edge.",
                ],
                "y": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Vertical position as fraction of screen height. " +
                        "0 = top edge, 1 = bottom edge.",
                ],
                "display": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "0-based display index (default: 0 = main). " +
                        "Match the index used when calling `screenshot`.",
                ],
                "label": [
                    "type": "string",
                    "description": "Very short caption shown in a pill next to the cursor. " +
                        "Keep it to 1–3 words, ideally under ~20 characters. This is a visual tag, " +
                        "not an explanation — your spoken/written words carry the explanation. " +
                        "Good: \"File menu\", \"Export\", \"Search bar\". " +
                        "Bad: \"Click here to export as PDF\" (too long — say that aloud instead).",
                ],
                "pulse": [
                    "type": "boolean",
                    "description": "Show a click-ripple at the target after arriving (default: true).",
                ],
                "hold_seconds": [
                    "type": "number",
                    "minimum": 0.5,
                    "maximum": 60.0,
                    "description": "How long the cursor stays visible AFTER arriving at the target, in seconds. " +
                        "Default 8.0 is right for most tips. Use 15-30 for complex explanations " +
                        "or when the user needs to read the labelled target. The timer starts only " +
                        "after the move animation finishes, so the full value is 'eyes-on time'.",
                ],
            ],
            "required": ["x", "y"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        let x = try Self.readNumber(args, key: "x")
        let y = try Self.readNumber(args, key: "y")
        guard (0.0 ... 1.0).contains(x) else {
            throw PointToolError.outOfRange(key: "x", value: x)
        }
        guard (0.0 ... 1.0).contains(y) else {
            throw PointToolError.outOfRange(key: "y", value: y)
        }

        let displayIndex = (args["display"] as? Int) ?? 0
        let label = args["label"] as? String
        let pulse = (args["pulse"] as? Bool) ?? true
        let explicitHold = (args["hold_seconds"] as? Double)
            ?? (args["hold_seconds"] as? Int).map(Double.init)

        let result = try await MainActor.run { () throws -> (CGSize, Int) in
            let available = VirtualCursorController.screenCount
            guard available > 0 else {
                throw PointToolError.noDisplays
            }
            guard let screen = VirtualCursorController.screen(forIndex: displayIndex) else {
                throw PointToolError.invalidDisplay(index: displayIndex, available: available)
            }
            let holdSeconds = explicitHold ?? VirtualCursorController.defaultHoldSeconds
            VirtualCursorController.show(
                atNormalizedX: x,
                y: y,
                on: screen,
                label: label,
                pulse: pulse,
                holdSeconds: holdSeconds
            )
            return (screen.frame.size, available)
        }

        let (size, available) = result
        let coordString = String(format: "(%.3f, %.3f)", x, y)
        logger.info("Pointed at \(coordString) on display \(displayIndex) [\(available) available]")

        let labelHint = label.map { " (\($0))" } ?? ""
        let text = "Virtual cursor moved to (\(format(x)), \(format(y))) on display \(displayIndex)"
            + " — \(Int(size.width))×\(Int(size.height))pt" + labelHint
        return ToolOutput(text: text)
    }

    // MARK: - Helpers

    private static func readNumber(_ args: [String: Any], key: String) throws -> Double {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? Int { return Double(value) }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String, let parsed = Double(value) { return parsed }
        throw PointToolError.missingArgument(key: key)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Errors

enum PointToolError: LocalizedError, Equatable {
    case missingArgument(key: String)
    case outOfRange(key: String, value: Double)
    case invalidDisplay(index: Int, available: Int)
    case noDisplays

    var errorDescription: String? {
        switch self {
        case let .missingArgument(key):
            "Missing required parameter: \(key)"
        case let .outOfRange(key, value):
            "Parameter '\(key)' = \(value) is out of range. Use a fraction between 0.0 and 1.0 " +
                "(0 = top/left edge, 1 = bottom/right edge)."
        case let .invalidDisplay(index, available):
            "Display index \(index) is out of range. Available displays: 0…\(max(0, available - 1))."
        case .noDisplays:
            "No displays are currently attached."
        }
    }
}
