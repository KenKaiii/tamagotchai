import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "sessions"
)

/// Persists chat sessions as individual JSON files in Application Support.
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [ChatSession] = []
    private(set) var activeSessionIDs: Set<UUID> = []

    private init() {
        loadAll()
    }

    // MARK: - Public API

    /// Loads all sessions from disk, sorted by updatedAt descending.
    func loadAll() {
        do {
            let dir = try Self.sessionsDirectory()
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else {
                logger.info("No sessions directory — starting fresh")
                sessions = []
                return
            }

            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var loaded: [ChatSession] = []
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    let session = try decoder.decode(ChatSession.self, from: data)
                    loaded.append(session)
                } catch {
                    logger.error("Failed to decode session \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }

            sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
            let count = sessions.count
            logger.info("Loaded \(count) sessions from disk")
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)")
            sessions = []
        }
    }

    /// Saves a session to disk. Updates the in-memory list.
    func save(session: ChatSession) {
        do {
            let dir = try Self.sessionsDirectory()
            let url = dir.appendingPathComponent("\(session.id.uuidString).json")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)

            // Update in-memory list
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = session
            } else {
                sessions.insert(session, at: 0)
            }
            sessions.sort { $0.updatedAt > $1.updatedAt }

            logger.debug("Saved session '\(session.title)' (\(session.messages.count) messages)")
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription)")
        }
    }

    /// Deletes a session from disk and memory.
    func delete(id: UUID) {
        do {
            let dir = try Self.sessionsDirectory()
            let url = dir.appendingPathComponent("\(id.uuidString).json")
            try FileManager.default.removeItem(at: url)
            sessions.removeAll { $0.id == id }
            logger.info("Deleted session \(id.uuidString)")
        } catch {
            logger.error("Failed to delete session \(id.uuidString): \(error.localizedDescription)")
        }
    }

    /// Returns a session by ID.
    func session(for id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    /// Groups chat sessions by date: "Today", "This Week", "This Month", "Older".
    func allSessionsGroupedByDate() -> [(label: String, sessions: [ChatSession])] {
        sessionsGroupedByDate(type: .chat)
    }

    /// Filters sessions of a given type by query (case-insensitive title match), grouped by date.
    func searchSessionsGroupedByDate(type: SessionType, query: String) -> [(label: String, sessions: [ChatSession])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return sessionsGroupedByDate(type: type) }

        let filtered = sessions.filter {
            $0.sessionType == type && $0.title.lowercased().contains(trimmed)
        }
        return groupSessionsByDate(filtered)
    }

    /// Groups sessions of a given type by date: "Today", "This Week", "This Month", "Older".
    func sessionsGroupedByDate(type: SessionType) -> [(label: String, sessions: [ChatSession])] {
        let filtered = sessions.filter { $0.sessionType == type }
        return groupSessionsByDate(filtered)
    }

    // MARK: - Active Session Tracking

    func markActive(_ id: UUID) {
        activeSessionIDs.insert(id)
        logger.debug("Session \(id.uuidString) marked active")
    }

    func markInactive(_ id: UUID) {
        activeSessionIDs.remove(id)
        logger.debug("Session \(id.uuidString) marked inactive")
    }

    // MARK: - Grouping

    private func groupSessionsByDate(_ list: [ChatSession]) -> [(label: String, sessions: [ChatSession])] {
        guard !list.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
            ?? startOfToday
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? startOfToday

        var today: [ChatSession] = []
        var thisWeek: [ChatSession] = []
        var thisMonth: [ChatSession] = []
        var older: [ChatSession] = []

        for session in list {
            if session.updatedAt >= startOfToday {
                today.append(session)
            } else if session.updatedAt >= startOfWeek {
                thisWeek.append(session)
            } else if session.updatedAt >= startOfMonth {
                thisMonth.append(session)
            } else {
                older.append(session)
            }
        }

        var result: [(label: String, sessions: [ChatSession])] = []
        if !today.isEmpty { result.append(("Today", today)) }
        if !thisWeek.isEmpty { result.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { result.append(("This Month", thisMonth)) }
        if !older.isEmpty { result.append(("Older", older)) }
        return result
    }

    /// Deletes the oldest sessions of a given type when count exceeds `max`.
    func pruneExcess(type: SessionType, max: Int) {
        let matching = sessions.filter { $0.sessionType == type }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard matching.count > max else { return }
        let toDelete = matching.suffix(from: max)
        for session in toDelete {
            delete(id: session.id)
        }
        logger.info("Pruned \(toDelete.count) excess \(type.rawValue) sessions")
    }

    // MARK: - Storage Path

    private static func sessionsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("Tama", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
