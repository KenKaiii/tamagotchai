import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.schedules"
)

/// Agent tool that deletes a scheduled job by name.
final class DeleteScheduleTool: AgentTool {
    let name = "delete_schedule"
    let description = "Delete a scheduled reminder or routine by name."

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "The name of the schedule to delete.",
                ],
            ],
            "required": ["name"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let name = args["name"] as? String else {
            throw DeleteScheduleError.missingParam("name")
        }

        let deleted = await ScheduleStore.shared.deleteJob(named: name)
        logger.info("Delete schedule '\(name)': \(deleted ? "success" : "not found")")

        if deleted {
            return "{\"success\": true, \"message\": \"Deleted schedule '\(name)'.\"}"
        } else {
            return "{\"success\": false, \"message\": \"No schedule found with name '\(name)'.\"}"
        }
    }
}

enum DeleteScheduleError: LocalizedError {
    case missingParam(String)

    var errorDescription: String? {
        switch self {
        case let .missingParam(param):
            "Missing required parameter: \(param)"
        }
    }
}
