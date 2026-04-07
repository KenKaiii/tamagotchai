import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.reminder"
)

/// Agent tool that creates a scheduled reminder notification.
final class CreateReminderTool: AgentTool {
    let name = "create_reminder"
    let description = """
    Create a reminder that will fire a macOS notification at the scheduled time. \
    Supports: "30m", "every 2h", "tomorrow 3pm", "in 10 minutes", cron expressions (e.g. "0 9 * * *").
    """

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "A short name for this reminder.",
                ],
                "schedule": [
                    "type": "string",
                    "description":
                        "When to fire: e.g. \"30m\", \"every 2h\", \"tomorrow 3pm\", \"in 10 minutes\", \"0 9 * * *\".",
                ],
                "message": [
                    "type": "string",
                    "description": "The reminder message to display in the notification.",
                ],
            ],
            "required": ["name", "schedule", "message"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let name = args["name"] as? String else {
            throw CreateReminderError.missingParam("name")
        }
        guard let schedule = args["schedule"] as? String else {
            throw CreateReminderError.missingParam("schedule")
        }
        guard let message = args["message"] as? String else {
            throw CreateReminderError.missingParam("message")
        }

        guard let parsed = ScheduleParser.parseSchedule(schedule) else {
            logger.warning("Failed to parse schedule: \(schedule)")
            return "{\"error\": \"Could not parse schedule: \(schedule)\"}"
        }

        let job = await ScheduleStore.shared.addJob(
            name: name,
            jobType: .reminder,
            parsed: parsed,
            prompt: message
        )

        logger.info("Created reminder '\(name)' nextRun=\(String(describing: job.nextRunAt))")

        let nextRun = job.nextRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return """
        {"success": true, "name": "\(name)", "type": "reminder", \
        "schedule_type": "\(parsed.type.rawValue)", "next_run": "\(nextRun)"}
        """
    }
}

enum CreateReminderError: LocalizedError {
    case missingParam(String)

    var errorDescription: String? {
        switch self {
        case let .missingParam(param):
            "Missing required parameter: \(param)"
        }
    }
}
