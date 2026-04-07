import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.schedules"
)

/// Agent tool that lists all active scheduled jobs.
final class ListSchedulesTool: AgentTool {
    let name = "list_schedules"
    let description = "List all active scheduled reminders and routines with their next run times."

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [:] as [String: Any],
        ]
    }

    func execute(args _: [String: Any]) async throws -> String {
        let jobs = await ScheduleStore.shared.listJobs()
        logger.info("Listing \(jobs.count) active schedules")

        if jobs.isEmpty {
            return "{\"schedules\": [], \"message\": \"No active schedules.\"}"
        }

        let formatter = ISO8601DateFormatter()
        let entries = jobs.map { job -> [String: String] in
            var entry: [String: String] = [
                "name": job.name,
                "type": job.jobType.rawValue,
                "schedule_type": job.scheduleType.rawValue,
                "enabled": String(job.enabled),
            ]
            if let nextRun = job.nextRunAt {
                entry["next_run"] = formatter.string(from: nextRun)
            }
            if let schedule = job.schedule {
                entry["schedule"] = schedule
            }
            if let interval = job.intervalSeconds {
                entry["interval_seconds"] = String(interval)
            }
            entry["prompt"] = job.prompt
            return entry
        }

        let data = try JSONSerialization.data(
            withJSONObject: ["schedules": entries],
            options: .prettyPrinted
        )
        return String(data: data, encoding: .utf8) ?? "{\"error\": \"serialization failed\"}"
    }
}
