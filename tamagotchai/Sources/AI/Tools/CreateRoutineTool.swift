import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.routine"
)

/// Agent tool that creates a scheduled routine — an LLM-triggered task that runs on a schedule.
final class CreateRoutineTool: AgentTool {
    let name = "create_routine"
    let description = """
    Create a routine that runs an LLM prompt on a schedule. The prompt is executed by the agent \
    and the result is delivered as a macOS notification. \
    Supports: "every 2h", "0 9 * * *" (cron), "tomorrow 3pm", "in 10 minutes".
    """

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A short name for this routine.",
                ],
                "schedule": [
                    "type": "string",
                    "description":
                        "When to run: e.g. \"every 2h\", \"0 9 * * *\", \"tomorrow 3pm\", \"in 10 minutes\".",
                ],
                "prompt": [
                    "type": "string",
                    "description": "The prompt to send to the agent when the routine fires.",
                ],
            ],
            "required": ["name", "schedule", "prompt"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let name = args["name"] as? String else {
            throw CreateRoutineError.missingParam("name")
        }
        guard let schedule = args["schedule"] as? String else {
            throw CreateRoutineError.missingParam("schedule")
        }
        guard let prompt = args["prompt"] as? String else {
            throw CreateRoutineError.missingParam("prompt")
        }

        guard let parsed = ScheduleParser.parseSchedule(schedule) else {
            logger.warning("Failed to parse schedule: \(schedule)")
            return "{\"error\": \"Could not parse schedule: \(schedule)\"}"
        }

        let job = await ScheduleStore.shared.addJob(
            name: name,
            jobType: .routine,
            parsed: parsed,
            prompt: prompt
        )

        logger.info("Created routine '\(name)' nextRun=\(String(describing: job.nextRunAt))")

        let nextRun = job.nextRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return """
        {"success": true, "name": "\(name)", "type": "routine", \
        "schedule_type": "\(parsed.type.rawValue)", "next_run": "\(nextRun)"}
        """
    }
}

enum CreateRoutineError: LocalizedError {
    case missingParam(String)

    var errorDescription: String? {
        switch self {
        case let .missingParam(param):
            "Missing required parameter: \(param)"
        }
    }
}
