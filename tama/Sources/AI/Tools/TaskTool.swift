import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.task"
)

/// Agent tool that manages task lists — create, update, and delete task lists and their items.
final class TaskTool: AgentTool {
    let name = "task"
    let description = """
    Create and manage task checklists stored for later execution. \
    Actions: "create" (new list), "update" (modify items), "delete" (remove list or items). \
    Tasks are NOT executed immediately — they appear in the Tasks Pane for manual run.
    """

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["create", "update", "delete"],
                    "description": "The operation to perform.",
                ],
                "title": [
                    "type": "string",
                    "description": "The title of the task list.",
                ],
                "items": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description":
                        "For create: item titles. For delete: specific items to remove (omit to delete entire list).",
                ],
                "add_items": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Items to add (update action only).",
                ],
                "remove_items": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Items to remove by title (update action only).",
                ],
                "check_items": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Items to mark as completed by title (update action only).",
                ],
                "uncheck_items": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Items to mark as not completed by title (update action only).",
                ],
            ],
            "required": ["action", "title"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let action = args["action"] as? String else {
            throw TaskToolError.missingParam("action")
        }
        guard let title = args["title"] as? String else {
            throw TaskToolError.missingParam("title")
        }

        let text: String = switch action {
        case "create":
            await handleCreate(title: title, args: args)
        case "update":
            await handleUpdate(title: title, args: args)
        case "delete":
            await handleDelete(title: title, args: args)
        default:
            "{\"error\": \"Unknown action: \(action). Use create, update, or delete.\"}"
        }
        return ToolOutput(text: text)
    }

    // MARK: - Create

    private func handleCreate(title: String, args: [String: Any]) async -> String {
        let itemTitles = args["items"] as? [String] ?? []

        let items = itemTitles.map { itemTitle in
            TaskItem(id: UUID(), title: itemTitle, isCompleted: false)
        }

        let now = Date()
        let taskList = TaskList(
            id: UUID(),
            title: title,
            items: items,
            createdAt: now,
            updatedAt: now,
            moodIcon: "afternoon"
        )

        await TaskStore.shared.save(taskList: taskList)
        logger.info("Created task list '\(title)' with \(items.count) items")

        return """
        {"success": true, "id": "\(taskList.id.uuidString)", \
        "title": "\(title)", "items_count": \(items.count)}
        """
    }

    // MARK: - Update

    private func handleUpdate(title: String, args: [String: Any]) async -> String {
        guard var taskList = await findTaskList(title: title) else {
            return "{\"error\": \"No task list found with title: \(title)\"}"
        }

        // Add new items
        if let addItems = args["add_items"] as? [String] {
            for itemTitle in addItems {
                taskList.items.append(
                    TaskItem(id: UUID(), title: itemTitle, isCompleted: false)
                )
            }
        }

        // Remove items by title
        if let removeItems = args["remove_items"] as? [String] {
            let lowered = Set(removeItems.map { $0.lowercased() })
            taskList.items.removeAll { lowered.contains($0.title.lowercased()) }
        }

        // Check items
        if let checkItems = args["check_items"] as? [String] {
            let lowered = Set(checkItems.map { $0.lowercased() })
            for i in taskList.items.indices where lowered.contains(taskList.items[i].title.lowercased()) {
                taskList.items[i].isCompleted = true
            }
        }

        // Uncheck items
        if let uncheckItems = args["uncheck_items"] as? [String] {
            let lowered = Set(uncheckItems.map { $0.lowercased() })
            for i in taskList.items.indices where lowered.contains(taskList.items[i].title.lowercased()) {
                taskList.items[i].isCompleted = false
            }
        }

        taskList.updatedAt = Date()
        await TaskStore.shared.save(taskList: taskList)
        logger.info("Updated task list '\(title)'")

        let completed = taskList.items.filter(\.isCompleted).count
        return """
        {"success": true, "title": "\(taskList.title)", \
        "total_items": \(taskList.items.count), "completed": \(completed)}
        """
    }

    // MARK: - Delete

    private func handleDelete(title: String, args: [String: Any]) async -> String {
        guard var taskList = await findTaskList(title: title) else {
            return "{\"error\": \"No task list found with title: \(title)\"}"
        }

        // If specific items are provided, delete only those items
        if let itemTitles = args["items"] as? [String], !itemTitles.isEmpty {
            let lowered = Set(itemTitles.map { $0.lowercased() })
            let before = taskList.items.count
            taskList.items.removeAll { lowered.contains($0.title.lowercased()) }
            let removed = before - taskList.items.count
            taskList.updatedAt = Date()
            await TaskStore.shared.save(taskList: taskList)
            logger.info("Removed \(removed) items from task list '\(title)'")
            return "{\"success\": true, \"items_removed\": \(removed), \"items_remaining\": \(taskList.items.count)}"
        }

        // Delete the entire list
        await TaskStore.shared.delete(id: taskList.id)
        logger.info("Deleted task list '\(title)'")
        return "{\"success\": true, \"deleted\": \"\(title)\"}"
    }

    // MARK: - Helpers

    private func findTaskList(title: String) async -> TaskList? {
        let allLists = await TaskStore.shared.taskLists
        return allLists.first { $0.title.lowercased() == title.lowercased() }
    }
}

// MARK: - Errors

enum TaskToolError: LocalizedError {
    case missingParam(String)

    var errorDescription: String? {
        switch self {
        case let .missingParam(name):
            "Missing required parameter: \(name)"
        }
    }
}
