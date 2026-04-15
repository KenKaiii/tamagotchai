import Foundation
import os
import UserNotifications

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "scheduler"
)

/// Persisted scheduled job — reminders produce notifications, routines invoke the agent.
struct ScheduledJob: Codable, Identifiable {
    let id: UUID
    var name: String
    var jobType: JobType
    var scheduleType: ScheduleType
    var schedule: String?
    var runAt: Date?
    var intervalSeconds: Int?
    var prompt: String
    var nextRunAt: Date?
    var deleteAfterRun: Bool
    var enabled: Bool
    var createdAt: Date
    var runCount: Int

    enum JobType: String, Codable { case reminder, routine }
    enum ScheduleType: String, Codable { case at, every, cron }

    init(
        id: UUID,
        name: String,
        jobType: JobType,
        scheduleType: ScheduleType,
        schedule: String?,
        runAt: Date?,
        intervalSeconds: Int?,
        prompt: String,
        nextRunAt: Date?,
        deleteAfterRun: Bool,
        enabled: Bool,
        createdAt: Date,
        runCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.jobType = jobType
        self.scheduleType = scheduleType
        self.schedule = schedule
        self.runAt = runAt
        self.intervalSeconds = intervalSeconds
        self.prompt = prompt
        self.nextRunAt = nextRunAt
        self.deleteAfterRun = deleteAfterRun
        self.enabled = enabled
        self.createdAt = createdAt
        self.runCount = runCount
    }

    // Custom decoder to handle legacy schedules without runCount
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        jobType = try container.decode(JobType.self, forKey: .jobType)
        scheduleType = try container.decode(ScheduleType.self, forKey: .scheduleType)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        runAt = try container.decodeIfPresent(Date.self, forKey: .runAt)
        intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        prompt = try container.decode(String.self, forKey: .prompt)
        nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        deleteAfterRun = try container.decode(Bool.self, forKey: .deleteAfterRun)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
    }
}

/// Manages scheduled jobs: persistence, polling, and execution.
@MainActor
final class ScheduleStore {
    static let shared = ScheduleStore()

    private(set) var jobs: [ScheduledJob] = []
    private var pollTimer: Timer?

    /// IDs of routines currently executing (for shimmer effect)
    private(set) var activeRoutineIDs: Set<UUID> = []

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    func start() {
        let count = jobs.count
        logger.info("Starting scheduler with \(count) jobs")
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDueJobs()
            }
        }
        // Run once immediately
        checkDueJobs()
    }

    func stop() {
        logger.info("Stopping scheduler")
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func addJob(
        name: String,
        jobType: ScheduledJob.JobType,
        parsed: ParsedSchedule,
        prompt: String
    ) -> ScheduledJob {
        let job = ScheduledJob(
            id: UUID(),
            name: name,
            jobType: jobType,
            scheduleType: parsed.type.toJobScheduleType,
            schedule: parsed.schedule,
            runAt: parsed.runAt,
            intervalSeconds: parsed.intervalSeconds,
            prompt: prompt,
            nextRunAt: parsed.runAt ?? ScheduleParser.calculateNextRun(
                type: parsed.type,
                schedule: parsed.schedule,
                runAt: parsed.runAt,
                intervalSeconds: parsed.intervalSeconds
            ),
            deleteAfterRun: parsed.type == .at,
            enabled: true,
            createdAt: Date(),
            runCount: 0
        )
        jobs.append(job)
        saveToDisk()
        logger.info("Added job '\(name)' type=\(jobType.rawValue) scheduleType=\(parsed.type.rawValue)")
        return job
    }

    func deleteJob(named name: String) -> Bool {
        let before = jobs.count
        jobs.removeAll { $0.name.lowercased() == name.lowercased() }
        if jobs.count < before {
            saveToDisk()
            logger.info("Deleted job '\(name)'")
            return true
        }
        return false
    }

    func deleteJob(id: UUID) -> Bool {
        let before = jobs.count
        jobs.removeAll { $0.id == id }
        if jobs.count < before {
            saveToDisk()
            logger.info("Deleted job \(id.uuidString)")
            return true
        }
        return false
    }

    func runRoutineNow(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id && $0.jobType == .routine }) else {
            logger.warning("Routine \(id.uuidString) not found or not a routine")
            return
        }
        logger.info("Manually triggering routine '\(job.name)'")
        executeRoutine(job)
    }

    func listJobs() -> [ScheduledJob] {
        jobs.filter(\.enabled)
    }

    // MARK: - Polling

    private func checkDueJobs() {
        let now = Date()
        var modified = false

        for i in jobs.indices.reversed() {
            guard jobs[i].enabled, let nextRun = jobs[i].nextRunAt, nextRun <= now else {
                continue
            }

            let job = jobs[i]
            logger.info("Job '\(job.name)' is due — executing")

            switch job.jobType {
            case .reminder:
                fireReminderNotification(job)
            case .routine:
                executeRoutine(job)
            }

            if job.deleteAfterRun {
                jobs.remove(at: i)
                logger.info("Removed one-shot job '\(job.name)'")
            } else {
                // Calculate next run
                jobs[i].nextRunAt = ScheduleParser.calculateNextRun(
                    type: ParsedSchedule.ScheduleType(rawValue: job.scheduleType.rawValue) ?? .at,
                    schedule: job.schedule,
                    runAt: nil,
                    intervalSeconds: job.intervalSeconds
                )
                let nextRun = jobs[i].nextRunAt
                logger.info("Next run for '\(job.name)': \(String(describing: nextRun))")
            }
            modified = true
        }

        if modified {
            saveToDisk()
        }
    }

    // MARK: - Notification

    private func fireReminderNotification(_ job: ScheduledJob) {
        // Notch notification for visual flair when screen is active
        NotchNotificationPresenter.showReminder(name: job.name, message: job.prompt)

        // Persist as an individual reminder session
        let reminderMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: [.text("**\(job.name)**\n\n\(job.prompt)")],
            timestamp: Date()
        )
        let reminderSession = ChatSession(
            id: UUID(),
            title: job.name,
            messages: [reminderMessage],
            createdAt: Date(),
            updatedAt: Date(),
            moodIcon: "⏰",
            sessionType: .reminders
        )
        SessionStore.shared.save(session: reminderSession)
        SessionStore.shared.pruneExcess(type: .reminders, max: 25)

        // System notification for Notification Center history
        let content = UNMutableNotificationContent()
        content.title = "Tama Reminder"
        content.subtitle = job.name
        content.body = job.prompt
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: job.id.uuidString,
            content: content,
            trigger: nil
        )

        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Delivered reminder notification for '\(job.name)'")
            } catch {
                logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Routine Execution

    func executeRoutine(_ job: ScheduledJob) {
        Task { @MainActor in
            logger.info("Running routine '\(job.name)' with prompt: \(job.prompt.prefix(100))")

            // Mark as active for shimmer effect
            activeRoutineIDs.insert(job.id)
            NotchActivityIndicator.addProcess(id: job.id.uuidString, label: "Routine: \(job.name)")

            // Increment run count
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].runCount += 1
                saveToDisk()
            }

            let agentLoop = AgentLoop()
            let messages: [[String: Any]] = [
                ["role": "user", "content": job.prompt],
            ]

            nonisolated(unsafe) var collectedText = ""
            var resultText: String
            do {
                _ = try await agentLoop.run(
                    messages: messages,
                    systemPrompt: "You are a helpful assistant running a scheduled routine. Be concise."
                ) { event in
                    if case let .turnComplete(text) = event {
                        collectedText = text
                    }
                }
                resultText = collectedText
            } catch {
                logger
                    .error(
                        "Routine '\(job.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                    )
                resultText = "Routine failed: \(error.localizedDescription)"
            }

            // Clean up any browser processes launched during the routine.
            BrowserManager.shared.disconnect()

            // Mark as inactive
            activeRoutineIDs.remove(job.id)
            NotchActivityIndicator.removeProcess(id: job.id.uuidString)

            // Persist as an individual routine session
            let userMsg = ChatMessage(
                id: UUID(),
                role: .user,
                content: [.text(job.prompt)],
                timestamp: Date()
            )
            let assistantMsg = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: [.text("**\(job.name)**\n\n\(resultText)")],
                timestamp: Date()
            )
            let routineSession = ChatSession(
                id: UUID(),
                title: job.name,
                messages: [userMsg, assistantMsg],
                createdAt: Date(),
                updatedAt: Date(),
                moodIcon: "⚡",
                sessionType: .routines
            )
            SessionStore.shared.save(session: routineSession)
            SessionStore.shared.pruneExcess(type: .routines, max: 25)

            // Notch notification for visual flair when screen is active
            NotchNotificationPresenter.showRoutineResult(name: job.name, result: resultText)

            // System notification for Notification Center history
            let content = UNMutableNotificationContent()
            content.title = job.name
            content.body = String(resultText.prefix(256))
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "\(job.id.uuidString)-result",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Failed to deliver routine notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private static func storageURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Tama", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }

    private func loadFromDisk() {
        do {
            let url = try Self.storageURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.info("No schedules file found — starting fresh")
                return
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([ScheduledJob].self, from: data)
            let loadedCount = jobs.count
            logger.info("Loaded \(loadedCount) scheduled jobs from disk")
        } catch {
            logger.error("Failed to load schedules: \(error.localizedDescription)")
            jobs = []
        }
    }

    private func saveToDisk() {
        do {
            let url = try Self.storageURL()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(jobs)
            try data.write(to: url, options: .atomic)
            let savedCount = jobs.count
            logger.debug("Saved \(savedCount) scheduled jobs to disk")
        } catch {
            logger.error("Failed to save schedules: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

extension ParsedSchedule.ScheduleType {
    var toJobScheduleType: ScheduledJob.ScheduleType {
        switch self {
        case .at: .at
        case .every: .every
        case .cron: .cron
        }
    }
}
