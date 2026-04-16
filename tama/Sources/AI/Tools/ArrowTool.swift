import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.arrow"
)

/// Agent tool that draws a filled orange arrow from point A to point B —
/// perfect for "drag this here", "data flows this way", "click this, result
/// appears there" guidance that `point` alone can't express.
struct ArrowTool: AgentTool, @unchecked Sendable {
    let name = "arrow"
    let description = """
    Draw a curved arrow from point A to point B on the user's screen. Use this when what you want \
    to convey is a DIRECTION or RELATIONSHIP — "drag from here to there", "data flows this way", \
    "click this and the result appears there". Trigger phrases: "drag X to Y", "move X over to Y", \
    "connect X and Y", "the result goes there".

    ## Coords
    Normalized (0, 0) = top-left, (1, 1) = bottom-right. `x1, y1` is the TAIL (start); `x2, y2` is \
    the ARROWHEAD (destination, where the eye should end up). Match `display` to the index used \
    when calling `screenshot`.

    ## Labels
    Keep the `label` to 1–3 words (~20 chars max). It's a visual tag ("Drag here"), not an \
    explanation — your voice/text carries the explanation.

    ## Style
    `solid` (default) for most cases. `dashed` for "suggested" / "optional" flows.

    ## When NOT to use
    - A single click target → use `point` instead.
    - An area to inspect → use `highlight` instead.
    - When the two endpoints are closer than ~2% of the screen — the arrow will look like a dot.
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "x1": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Horizontal fraction of the arrow's TAIL (start).",
                ],
                "y1": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Vertical fraction of the arrow's TAIL (start).",
                ],
                "x2": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Horizontal fraction of the arrow's HEAD (tip lands here).",
                ],
                "y2": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Vertical fraction of the arrow's HEAD (tip lands here).",
                ],
                "label": [
                    "type": "string",
                    "description": "Very short caption shown in a pill at the arrow's midpoint. " +
                        "Keep it to 1–3 words, ~20 characters max (e.g. \"Drag here\").",
                ],
                "style": [
                    "type": "string",
                    "enum": ["solid", "dashed"],
                    "description": "`solid` for most flows; `dashed` for optional/suggested flows.",
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
                    "description": "How long the arrow stays visible, in seconds. Default 8.",
                ],
            ],
            "required": ["x1", "y1", "x2", "y2"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        let x1 = try Self.readNumber(args, key: "x1")
        let y1 = try Self.readNumber(args, key: "y1")
        let x2 = try Self.readNumber(args, key: "x2")
        let y2 = try Self.readNumber(args, key: "y2")
        for (key, value) in [("x1", x1), ("y1", y1), ("x2", x2), ("y2", y2)] {
            guard (0.0 ... 1.0).contains(value) else {
                throw ArrowToolError.outOfRange(key: key, value: value)
            }
        }

        // Minimum length check — an arrow shorter than ~20pt won't render
        // with a visible arrowhead. Use the smallest screen axis as the
        // scale to keep this test display-agnostic.
        let minFraction = 0.02
        let dx = x2 - x1
        let dy = y2 - y1
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= minFraction else {
            throw ArrowToolError.tooShort(length: length)
        }

        let styleRaw = (args["style"] as? String) ?? "solid"
        guard let style = VirtualCursorPanel.ArrowStyle(rawValue: styleRaw) else {
            throw ArrowToolError.invalidStyle(styleRaw)
        }

        let displayIndex = (args["display"] as? Int) ?? 0
        let label = args["label"] as? String
        let explicitHold = (args["hold_seconds"] as? Double)
            ?? (args["hold_seconds"] as? Int).map(Double.init)
        let holdSeconds = explicitHold ?? 8.0

        let available = try await MainActor.run { () throws -> Int in
            let count = VirtualCursorController.screenCount
            guard count > 0 else {
                throw ArrowToolError.noDisplays
            }
            guard let screen = VirtualCursorController.screen(forIndex: displayIndex) else {
                throw ArrowToolError.invalidDisplay(index: displayIndex, available: count)
            }
            VirtualCursorController.showArrow(
                x1: x1, y1: y1, x2: x2, y2: y2,
                on: screen,
                label: label,
                style: style,
                holdSeconds: holdSeconds
            )
            return count
        }

        logger.info(
            "Arrow (\(x1), \(y1)) → (\(x2), \(y2)) on display \(displayIndex) [\(available) total]"
        )
        let labelHint = label.map { " (\($0))" } ?? ""
        let text = "Arrow drawn from (\(format(x1)), \(format(y1)))" +
            " to (\(format(x2)), \(format(y2)))" +
            " on display \(displayIndex), style \(style.rawValue)" + labelHint
        return ToolOutput(text: text)
    }

    // MARK: - Helpers

    private static func readNumber(_ args: [String: Any], key: String) throws -> Double {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? Int { return Double(value) }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String, let parsed = Double(value) { return parsed }
        throw ArrowToolError.missingArgument(key: key)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Errors

enum ArrowToolError: LocalizedError, Equatable {
    case missingArgument(key: String)
    case outOfRange(key: String, value: Double)
    case invalidStyle(String)
    case tooShort(length: Double)
    case invalidDisplay(index: Int, available: Int)
    case noDisplays

    var errorDescription: String? {
        switch self {
        case let .missingArgument(key):
            "Missing required parameter: \(key)"
        case let .outOfRange(key, value):
            "Parameter '\(key)' = \(value) is out of range. Use a fraction in [0, 1]."
        case let .invalidStyle(value):
            "Invalid style '\(value)'. Use 'solid' or 'dashed'."
        case let .tooShort(length):
            "Arrow length \(length) is too short to render an arrowhead. " +
                "Use endpoints at least 2% of the screen apart."
        case let .invalidDisplay(index, available):
            "Display index \(index) is out of range. Available displays: 0…\(max(0, available - 1))."
        case .noDisplays:
            "No displays are currently attached."
        }
    }
}
