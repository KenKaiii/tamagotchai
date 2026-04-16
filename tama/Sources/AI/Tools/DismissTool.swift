import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.dismiss"
)

/// Notification posted when the agent requests dismissal of the chat panel.
extension Notification.Name {
    static let agentRequestedDismiss = Notification.Name("agentRequestedDismiss")
}

/// Tool that allows the agent to close the chat panel, ending the conversation.
struct DismissTool: AgentTool, @unchecked Sendable {
    let name = "dismiss"
    // swiftlint:disable:next line_length
    let description = "Close the chat panel and end the conversation. Use when the user is done, e.g. 'thanks', 'that's all', 'bye'. Do NOT send any text response before calling this tool."

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String],
    ]

    func execute(args _: [String: Any]) async throws -> ToolOutput {
        logger.info("Dismiss tool invoked — requesting panel close")
        await MainActor.run {
            NotificationCenter.default.post(name: .agentRequestedDismiss, object: nil)
        }
        return ToolOutput(text: "Panel dismiss requested.")
    }
}
