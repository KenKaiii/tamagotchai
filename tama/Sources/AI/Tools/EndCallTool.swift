import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.endcall"
)

/// Thrown when the agent invokes the end_call tool to hang up.
struct AgentEndCallError: Error {}

/// Tool that allows the agent to end the voice call.
struct EndCallTool: AgentTool, @unchecked Sendable {
    let name = "end_call"
    let description =
        "End the voice call and hang up. Use when the user says goodbye, e.g. 'bye', 'talk later', 'hang up', 'that's all'. Say a brief goodbye before calling this."

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String],
    ]

    func execute(args _: [String: Any]) async throws -> String {
        logger.info("End call tool invoked")
        return "Call ending."
    }
}
