import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.scrollhint"
)

/// Agent tool that shows a pulsing directional chevron at a screen edge to
/// hint "scroll this way". Better than saying "scroll down" when the user
/// can't immediately tell which side the thing is on.
struct ScrollHintTool: AgentTool, @unchecked Sendable {
    let name = "scroll_hint"
    let description = """
    Show a pulsing orange chevron at a screen edge to hint the user should scroll in that \
    direction. Use when the content you're talking about is offscreen and the user needs to \
    scroll to find it. Trigger phrases: "scroll down to see X", "scroll left for the sidebar", \
    "keep scrolling", "it's further down".

    ## Directions
    - `down` — chevron at the bottom edge, nudging downward. "Scroll down for more."
    - `up` — chevron at the top edge. "Scroll up to see the top."
    - `left` / `right` — chevrons at the side edges. Good for horizontal paged content.

    ## When NOT to use
    - When you can see the target on-screen → use `point` or `highlight`.
    - When "it's offscreen" is just a guess — take a `screenshot` first, confirm it's not visible.
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "direction": [
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "Direction the user should scroll.",
                ],
                "label": [
                    "type": "string",
                    "description": "Optional very short caption shown next to the chevron " +
                        "(e.g. \"Keep scrolling\"). 1–3 words.",
                ],
                "display": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "0-based display index (default: 0 = main).",
                ],
                "hold_seconds": [
                    "type": "number",
                    "minimum": 1.0,
                    "maximum": 30.0,
                    "description": "How long the chevron stays visible, in seconds. Default 5.",
                ],
            ],
            "required": ["direction"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        let directionRaw = args["direction"] as? String ?? ""
        guard let direction = VirtualCursorPanel.ScrollDirection(rawValue: directionRaw) else {
            throw ScrollHintToolError.invalidDirection(directionRaw)
        }

        let displayIndex = (args["display"] as? Int) ?? 0
        let label = args["label"] as? String
        let explicitHold = (args["hold_seconds"] as? Double)
            ?? (args["hold_seconds"] as? Int).map(Double.init)
        let holdSeconds = explicitHold ?? 5.0
        guard (1.0 ... 30.0).contains(holdSeconds) else {
            throw ScrollHintToolError.outOfRange(key: "hold_seconds", value: holdSeconds)
        }

        try await MainActor.run { () throws in
            let available = VirtualCursorController.screenCount
            guard available > 0 else { throw ScrollHintToolError.noDisplays }
            guard let screen = VirtualCursorController.screen(forIndex: displayIndex) else {
                throw ScrollHintToolError.invalidDisplay(index: displayIndex, available: available)
            }
            VirtualCursorController.showScrollHint(
                direction: direction,
                on: screen,
                label: label,
                holdSeconds: holdSeconds
            )
        }

        logger.info("Scroll hint \(direction.rawValue, privacy: .public) on display \(displayIndex)")
        let labelHint = label.map { " (\($0))" } ?? ""
        let text = "Scroll hint \(direction.rawValue) shown on display \(displayIndex)" + labelHint
        return ToolOutput(text: text)
    }
}

// MARK: - Errors

enum ScrollHintToolError: LocalizedError, Equatable {
    case invalidDirection(String)
    case outOfRange(key: String, value: Double)
    case invalidDisplay(index: Int, available: Int)
    case noDisplays

    var errorDescription: String? {
        switch self {
        case let .invalidDirection(value):
            "Invalid direction '\(value)'. Use 'up', 'down', 'left', or 'right'."
        case let .outOfRange(key, value):
            "Parameter '\(key)' = \(value) is out of range."
        case let .invalidDisplay(index, available):
            "Display index \(index) is out of range. Available displays: 0…\(max(0, available - 1))."
        case .noDisplays:
            "No displays are currently attached."
        }
    }
}
