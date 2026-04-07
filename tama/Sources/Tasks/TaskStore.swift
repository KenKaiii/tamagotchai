import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tasks"
)

/// Persists task lists as individual JSON files in Application Support.
@MainActor
final class TaskStore {
    static let shared = TaskStore()

    private(set) var taskLists: [TaskList] = []

    private init() {
        loadAll()
    }

    // MARK: - Public API

    /// Loads all task lists from disk, sorted by updatedAt descending.
    func loadAll() {
        do {
            let dir = try Self.tasksDirectory()
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else {
                logger.info("No tasks directory — starting fresh")
                taskLists = []
                return
            }

            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var loaded: [TaskList] = []
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    let taskList = try decoder.decode(TaskList.self, from: data)
                    loaded.append(taskList)
                } catch {
                    logger.error("Failed to decode task list \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }

            taskLists = loaded.sorted { $0.updatedAt > $1.updatedAt }
            let count = taskLists.count
            logger.info("Loaded \(count) task lists from disk")
        } catch {
            logger.error("Failed to load task lists: \(error.localizedDescription)")
            taskLists = []
        }
    }

    /// Saves a task list to disk. Updates the in-memory list.
    func save(taskList: TaskList) {
        do {
            let dir = try Self.tasksDirectory()
            let url = dir.appendingPathComponent("\(taskList.id.uuidString).json")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(taskList)
            try data.write(to: url, options: .atomic)

            // Update in-memory list
            if let idx = taskLists.firstIndex(where: { $0.id == taskList.id }) {
                taskLists[idx] = taskList
            } else {
                taskLists.insert(taskList, at: 0)
            }
            taskLists.sort { $0.updatedAt > $1.updatedAt }

            logger.debug("Saved task list '\(taskList.title)' (\(taskList.items.count) items)")
        } catch {
            logger.error("Failed to save task list: \(error.localizedDescription)")
        }
    }

    /// Deletes a task list from disk and memory.
    func delete(id: UUID) {
        do {
            let dir = try Self.tasksDirectory()
            let url = dir.appendingPathComponent("\(id.uuidString).json")
            try FileManager.default.removeItem(at: url)
            taskLists.removeAll { $0.id == id }
            logger.info("Deleted task list \(id.uuidString)")
        } catch {
            logger.error("Failed to delete task list \(id.uuidString): \(error.localizedDescription)")
        }
    }

    /// Returns a task list by ID.
    func taskList(for id: UUID) -> TaskList? {
        taskLists.first { $0.id == id }
    }

    /// Filters task lists by query, matching against the title and item titles (case-insensitive).
    /// Returns grouped results by date, or all if the query is empty.
    func searchGroupedByDate(query: String) -> [(label: String, taskLists: [TaskList])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allTaskListsGroupedByDate() }

        let filtered = taskLists.filter { taskList in
            taskList.title.lowercased().contains(trimmed)
                || taskList.items.contains { $0.title.lowercased().contains(trimmed) }
        }
        return groupByDate(filtered)
    }

    /// Groups task lists by date: "Today", "This Week", "This Month", "Older".
    func allTaskListsGroupedByDate() -> [(label: String, taskLists: [TaskList])] {
        groupByDate(taskLists)
    }

    // MARK: - Grouping

    private func groupByDate(_ lists: [TaskList]) -> [(label: String, taskLists: [TaskList])] {
        guard !lists.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
            ?? startOfToday
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? startOfToday

        var today: [TaskList] = []
        var thisWeek: [TaskList] = []
        var thisMonth: [TaskList] = []
        var older: [TaskList] = []

        for taskList in lists {
            if taskList.updatedAt >= startOfToday {
                today.append(taskList)
            } else if taskList.updatedAt >= startOfWeek {
                thisWeek.append(taskList)
            } else if taskList.updatedAt >= startOfMonth {
                thisMonth.append(taskList)
            } else {
                older.append(taskList)
            }
        }

        var result: [(label: String, taskLists: [TaskList])] = []
        if !today.isEmpty { result.append(("Today", today)) }
        if !thisWeek.isEmpty { result.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { result.append(("This Month", thisMonth)) }
        if !older.isEmpty { result.append(("Older", older)) }
        return result
    }

    // MARK: - Storage Path

    private static func tasksDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("Tama", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
