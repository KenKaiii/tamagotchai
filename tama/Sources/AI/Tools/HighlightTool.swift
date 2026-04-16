import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.highlight"
)

/// Agent tool that draws a dashed orange outline around a REGION of the
/// user's screen. Better than `point` when the target is an area (a toolbar,
/// a panel, a group of icons) rather than a single pixel target.
struct HighlightTool: AgentTool, @unchecked Sendable {
    let name = "highlight"
    let description = """
    Draw a dashed orange outline around an AREA on the user's screen — a toolbar, a panel, a \
    group of icons, a column. Use this INSTEAD of `point` when what you want to show is a \
    region, not a single button. Trigger phrases: "look at this panel", "this whole toolbar", \
    "the sidebar", "the top section".

    ## When to use
    - "what's in this section?" → screenshot → highlight the section
    - "this whole toolbar does X" → highlight the toolbar
    - Grouping a cluster of related icons for the user to scan
    - Calling attention to a container (a card, a dialog, a panel)

    ## Shapes
    - `rectangle` — the default; use for toolbars, panels, columns, rows. Width/height both in \
      normalized [0, 1].
    - `circle` — use for round targets (an avatar, a dot, a badge). `width` is the diameter; \
      `height` is ignored.

    ## Coords
    Normalized (0, 0) = top-left, (1, 1) = bottom-right. `x`, `y` are the top-left of the \
    rectangle (or the centre of the circle). Match `display` to the index used when calling \
    `screenshot`.

    ## Label
    Keep the label to 1–3 words (~20 chars max). It's a visual tag ("Toolbar", "Sidebar"), not \
    an explanation. The explanation goes in your spoken/written reply.
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "shape": [
                    "type": "string",
                    "enum": ["rectangle", "circle"],
                    "description": "`rectangle` for areas, `circle` for round targets (avatars, badges).",
                ],
                "x": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Left edge of the rectangle (or centre of the circle) as a " +
                        "fraction of screen width.",
                ],
                "y": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Top edge of the rectangle (or centre of the circle) as a " +
                        "fraction of screen height.",
                ],
                "width": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Width as a fraction of screen width. For circles, this is " +
                        "the diameter.",
                ],
                "height": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Height as a fraction of screen height. Ignored for circles.",
                ],
                "label": [
                    "type": "string",
                    "description": "Very short caption shown in a pill near the top-right of the shape. " +
                        "Keep it to 1–3 words, ~20 characters max (e.g. \"Toolbar\", \"Sidebar\").",
                ],
                "display": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "0-based display index (default: 0 = main).",
                ],
                "hold_seconds": [
                    "type": "number",
                    "minimum": 0.5,
                    "maximum": 120.0,
                    "description": "How long the highlight stays visible, in seconds. Default 10.",
                ],
            ],
            "required": ["shape", "x", "y", "width"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        let shapeRaw = args["shape"] as? String ?? ""
        guard let shape = VirtualCursorPanel.HighlightShape(rawValue: shapeRaw) else {
            throw HighlightToolError.invalidShape(shapeRaw)
        }

        let x = try Self.readNumber(args, key: "x")
        let y = try Self.readNumber(args, key: "y")
        let width = try Self.readNumber(args, key: "width")
        // Circles ignore height but rectangles require it; default height
        // equals width for squares so shape == .circle with only width given
        // still works.
        let height = (args["height"] as? Double)
            ?? (args["height"] as? Int).map(Double.init)
            ?? (shape == .circle ? width : width)
        guard (0.0 ... 1.0).contains(x) else { throw HighlightToolError.outOfRange(key: "x", value: x) }
        guard (0.0 ... 1.0).contains(y) else { throw HighlightToolError.outOfRange(key: "y", value: y) }
        guard (0.0 ... 1.0).contains(width), width > 0 else {
            throw HighlightToolError.outOfRange(key: "width", value: width)
        }
        guard (0.0 ... 1.0).contains(height), height > 0 else {
            throw HighlightToolError.outOfRange(key: "height", value: height)
        }

        let displayIndex = (args["display"] as? Int) ?? 0
        let label = args["label"] as? String
        let explicitHold = (args["hold_seconds"] as? Double)
            ?? (args["hold_seconds"] as? Int).map(Double.init)
        let holdSeconds = explicitHold ?? 10.0

        let result = try await MainActor.run { () throws -> (CGSize, Int) in
            let available = VirtualCursorController.screenCount
            guard available > 0 else {
                throw HighlightToolError.noDisplays
            }
            guard let screen = VirtualCursorController.screen(forIndex: displayIndex) else {
                throw HighlightToolError.invalidDisplay(index: displayIndex, available: available)
            }
            VirtualCursorController.showHighlight(
                shape: shape,
                x: x,
                y: y,
                width: width,
                height: height,
                on: screen,
                label: label,
                holdSeconds: holdSeconds
            )
            return (screen.frame.size, available)
        }

        let (size, _) = result
        logger.info("Highlighted \(shape.rawValue, privacy: .public) on display \(displayIndex)")
        let labelHint = label.map { " (\($0))" } ?? ""
        let text = "Highlighted \(shape.rawValue) at (\(format(x)), \(format(y)))" +
            " size \(format(width))x\(format(height)) on display \(displayIndex)" +
            " — \(Int(size.width))×\(Int(size.height))pt" + labelHint
        return ToolOutput(text: text)
    }

    // MARK: - Helpers

    private static func readNumber(_ args: [String: Any], key: String) throws -> Double {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? Int { return Double(value) }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String, let parsed = Double(value) { return parsed }
        throw HighlightToolError.missingArgument(key: key)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Errors

enum HighlightToolError: LocalizedError, Equatable {
    case missingArgument(key: String)
    case invalidShape(String)
    case outOfRange(key: String, value: Double)
    case invalidDisplay(index: Int, available: Int)
    case noDisplays

    var errorDescription: String? {
        switch self {
        case let .missingArgument(key):
            "Missing required parameter: \(key)"
        case let .invalidShape(value):
            "Invalid shape '\(value)'. Use 'rectangle' or 'circle'."
        case let .outOfRange(key, value):
            "Parameter '\(key)' = \(value) is out of range. Use a fraction in [0, 1]."
        case let .invalidDisplay(index, available):
            "Display index \(index) is out of range. Available displays: 0…\(max(0, available - 1))."
        case .noDisplays:
            "No displays are currently attached."
        }
    }
}
