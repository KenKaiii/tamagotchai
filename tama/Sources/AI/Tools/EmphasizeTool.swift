import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.emphasize"
)

/// Re-pulses the virtual cursor at its current position without moving it.
/// Use this when you want to draw attention to the thing you're already
/// pointing at (e.g. "click THIS one") — the cursor stays put, a fresh orange
/// ripple fires, and on supported trackpads the user also feels a light
/// haptic tick. It's the closest thing to "pulse on a spoken word" that fits
/// a turn-based tool-calling system.
///
/// Errors quietly: if no cursor is currently visible, returns a clear message
/// so the agent knows to call `point` first instead of `emphasize`.
struct EmphasizeTool: AgentTool, @unchecked Sendable {
    let name = "emphasize"
    let description = """
    Pulse the virtual cursor at its current position to draw attention to what you're \
    pointing at. Does NOT move the cursor — use `point` for that. Best used after a `point` \
    call when you want to emphasize ("this one", "right here") without changing targets. \
    Fires a visual ripple and a subtle haptic tick. Requires a visible cursor — call `point` \
    first if there isn't one.
    """

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String],
    ]

    func execute(args _: [String: Any]) async throws -> ToolOutput {
        let fired = await MainActor.run {
            VirtualCursorController.emphasize()
        }
        if fired {
            logger.info("Emphasize pulse fired at current cursor position")
            return ToolOutput(text: "Pulsed the virtual cursor at its current position.")
        }
        logger.info("Emphasize ignored — no visible cursor to pulse")
        return ToolOutput(
            text: "No virtual cursor is currently visible — call `point` first, " +
                "then `emphasize` to pulse it."
        )
    }
}
