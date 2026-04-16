import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.countdown"
)

/// Agent tool that displays a visible depleting ring countdown. Use when
/// teaching time-sensitive actions ("I'll start the recording in three
/// seconds...") or when you want the user to take a breath and prepare.
struct CountdownTool: AgentTool, @unchecked Sendable {
    let name = "countdown"
    let description = """
    Show a visible 3-2-1 style countdown ring on screen for `seconds` seconds. The ring depletes \
    clockwise, a centred number counts down, and the user feels a light haptic tick each second.

    ## When to use
    - Teaching time-sensitive stuff: "I'll hit record in three seconds..." — call `countdown` with \
      `seconds: 3`, then narrate.
    - Pacing ("take a breath, give it five seconds to load") — pair with your own narration.
    - Giving the user prep time before a fast action they'll perform themselves.

    ## IMPORTANT: This does NOT click anything.
    The countdown is a visual cue for pacing — the user acts when it hits zero. You POINT, they CLICK.

    Pair with narration: call `countdown`, then describe what they should do ("get ready to click \
    File when the ring finishes...").
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "seconds": [
                    "type": "number",
                    "minimum": 1.0,
                    "maximum": 30.0,
                    "description": "How many seconds the ring takes to deplete (1-30).",
                ],
                "x": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Horizontal centre of the ring as a fraction of screen width. " +
                        "Defaults to 0.5 (centre).",
                ],
                "y": [
                    "type": "number",
                    "minimum": 0.0,
                    "maximum": 1.0,
                    "description": "Vertical centre of the ring as a fraction of screen height. " +
                        "Defaults to 0.5 (centre).",
                ],
                "label": [
                    "type": "string",
                    "description": "Short caption shown below the number in the ring (e.g. \"Get ready\"). " +
                        "Keep it to 1–3 words.",
                ],
                "display": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "0-based display index (default: 0 = main).",
                ],
            ],
            "required": ["seconds"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        let seconds = try Self.readNumber(args, key: "seconds")
        guard (1.0 ... 30.0).contains(seconds) else {
            throw CountdownToolError.outOfRange(key: "seconds", value: seconds)
        }

        let x = (args["x"] as? Double) ?? (args["x"] as? Int).map(Double.init)
        let y = (args["y"] as? Double) ?? (args["y"] as? Int).map(Double.init)
        if let x, !(0.0 ... 1.0).contains(x) {
            throw CountdownToolError.outOfRange(key: "x", value: x)
        }
        if let y, !(0.0 ... 1.0).contains(y) {
            throw CountdownToolError.outOfRange(key: "y", value: y)
        }

        let displayIndex = (args["display"] as? Int) ?? 0
        let label = args["label"] as? String

        try await MainActor.run { () throws in
            let available = VirtualCursorController.screenCount
            guard available > 0 else { throw CountdownToolError.noDisplays }
            guard let screen = VirtualCursorController.screen(forIndex: displayIndex) else {
                throw CountdownToolError.invalidDisplay(index: displayIndex, available: available)
            }
            VirtualCursorController.showCountdown(
                seconds: seconds,
                x: x,
                y: y,
                on: screen,
                label: label
            )
        }

        logger.info("Countdown \(seconds)s on display \(displayIndex)")
        let labelHint = label.map { " (\($0))" } ?? ""
        let text = "Countdown started: \(Int(seconds))s on display \(displayIndex)" + labelHint
        return ToolOutput(text: text)
    }

    private static func readNumber(_ args: [String: Any], key: String) throws -> Double {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? Int { return Double(value) }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        throw CountdownToolError.missingArgument(key: key)
    }
}

// MARK: - Errors

enum CountdownToolError: LocalizedError, Equatable {
    case missingArgument(key: String)
    case outOfRange(key: String, value: Double)
    case invalidDisplay(index: Int, available: Int)
    case noDisplays

    var errorDescription: String? {
        switch self {
        case let .missingArgument(key):
            "Missing required parameter: \(key)"
        case let .outOfRange(key, value):
            "Parameter '\(key)' = \(value) is out of range. 'seconds' must be 1-30; coords must be [0, 1]."
        case let .invalidDisplay(index, available):
            "Display index \(index) is out of range. Available displays: 0…\(max(0, available - 1))."
        case .noDisplays:
            "No displays are currently attached."
        }
    }
}
