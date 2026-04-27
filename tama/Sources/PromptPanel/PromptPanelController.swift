import AppKit
import Carbon.HIToolbox
import os
import UserNotifications

/// Manages the floating prompt panel lifecycle and global hotkey registration.
@MainActor
final class PromptPanelController {
    static let shared = PromptPanelController()
    private let logger = Logger(subsystem: "com.unstablemind.tama", category: "controller")

    private var panel: FloatingPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var conversationHistory: [[String: Any]] = []
    private var currentSession: ChatSession?
    private var isVoiceMode = false
    private var isDismissedByAgent = false
    private var isPanelDismissed = false
    private var activeAgentTask: Task<Void, Never>?
    private var activeStreamTask: Task<Void, Never>?
    private var ttsUnloadTask: Task<Void, Never>?
    private lazy var agentLoop = AgentLoop(
        workingDirectory: Self.ensureWorkspace()
    )
    private var currentTab: SessionTab = .chats
    private var dismissObserver: NSObjectProtocol?

    /// Returns the workspace root, creating it (and the Screenshots subdirectory) if needed.
    ///
    /// The workspace lives under `~/Library/Application Support/Tama/Workspace/` rather
    /// than `~/Documents/Tama` because Application Support is **not** TCC-protected for
    /// non-sandboxed apps — macOS never prompts the user for access, and reinstalls or
    /// signature changes don't trigger fresh "allow access" dialogs. Putting the
    /// workspace under Documents would re-prompt every time the binary signature
    /// changes (Debug ↔ Release ↔ CI build), which is a poor UX.
    static func ensureWorkspace() -> String {
        let workspace = workspaceURL()
        if !FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }
        let screenshots = workspace.appendingPathComponent("Screenshots")
        if !FileManager.default.fileExists(atPath: screenshots.path) {
            try? FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        }
        return workspace.path
    }

    /// The path to the Screenshots directory inside the workspace.
    static var screenshotsDirectory: String {
        workspaceURL().appendingPathComponent("Screenshots").path
    }

    private static func workspaceURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Tama", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    // MARK: - Public

    /// Registers the global hotkey.
    func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey)
    ) {
        registerCarbonHotKey(keyCode: keyCode, modifiers: modifiers)
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .agentRequestedDismiss,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logger.info("Agent requested dismiss — closing panel")
                self?.panel?.dismiss()
            }
        }
    }

    /// Unregisters the hotkey and cleans up.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let dismissObserver {
            NotificationCenter.default.removeObserver(dismissObserver)
            self.dismissObserver = nil
        }
    }

    /// Toggles the panel. Opens with voice+typing ready. If already open, dismisses.
    func toggle() {
        let isVisible = panel?.isVisible ?? false
        logger.info("Toggle panel (currently visible: \(isVisible))")
        if let panel, panel.isVisible {
            panel.dismiss()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        logger.info("Showing panel")
        NotchActivityIndicator.removeProcess(id: "chat-agent")

        // Cancel any pending TTS unload — user reopened the panel
        ttsUnloadTask?.cancel()
        ttsUnloadTask = nil

        // Cancel UI tasks (stream, TTS, voice) but let the agent task keep
        // running in the background — it will save its result independently.
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeAgentTask = nil // detach, don't cancel — task keeps running
        SpeechService.shared.stop()
        VoiceService.shared.stopFollowUpCapture()
        panel?.hideToolIndicator()
        panel?.hideThinkingIndicator()
        MenuBarMood.shared.setActivity(nil)

        isDismissedByAgent = false
        isPanelDismissed = false
        isVoiceMode = false
        currentSession = nil
        currentTab = .chats
        ensurePanel()
        conversationHistory = []
        panel?.present()

        // Show recent sessions if any exist (already loaded from disk on init)
        let groups = SessionStore.shared.allSessionsGroupedByDate()
        if groups.isEmpty {
            panel?.showSessionList([], emptyMessage: "No conversations yet. Start chatting with Tama!")
        } else {
            panel?.showSessionList(groups)
        }

        // Start voice capture alongside typing — user decides by their action
        startVoiceCapture()
    }

    /// Cancels and nils all active tasks, stops TTS and voice capture,
    /// and resets the tool indicator. Safe to call even if nothing is active.
    private func cancelAllActiveTasks(clearHistory: Bool = false) {
        NotchActivityIndicator.removeProcess(id: "chat-agent")
        activeAgentTask?.cancel()
        activeStreamTask?.cancel()
        activeAgentTask = nil
        activeStreamTask = nil
        SpeechService.shared.stop()
        VoiceService.shared.stopFollowUpCapture()
        BrowserManager.shared.disconnect()
        panel?.hideToolIndicator()
        panel?.hideThinkingIndicator()
        MenuBarMood.shared.setActivity(nil)
        if clearHistory {
            conversationHistory.removeAll()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let newPanel = FloatingPanel()
        newPanel.onSubmit = { [weak self] text in
            self?.handleSubmit(text)
        }
        newPanel.onTextChanged = { [weak self, weak newPanel] text in
            guard let self, let newPanel else { return }
            if text.isEmpty {
                newPanel.mascot.setState(.idle)
                // Re-show session list when input is cleared
                let groups = SessionStore.shared.allSessionsGroupedByDate()
                if groups.isEmpty {
                    newPanel.showSessionList([], emptyMessage: "No conversations yet. Start chatting with Tama!")
                } else {
                    newPanel.showSessionList(groups)
                }
            } else {
                newPanel.mascot.notifyKeystroke()
                // Hide session list when user starts typing
                newPanel.hideSessionList()
                // User started typing — this is NOT voice mode, ensure we respond in text
                if isVoiceMode {
                    logger.info("User typing — switching from voice to typing mode")
                    isVoiceMode = false
                }
                // Also cancel any active voice capture
                if VoiceService.shared.state == .followUp {
                    SpeechService.shared.stop()
                    VoiceService.shared.stopFollowUpCapture()
                    newPanel.hideWaveformForTyping()
                }
            }
        }
        newPanel.onSelectSession = { [weak self] session in
            self?.loadSession(session)
        }
        newPanel.onDeleteSession = { [weak self] session in
            self?.deleteSession(session)
        }
        newPanel.onTabChanged = { [weak self] tab in
            self?.handleTabChanged(tab)
        }
        newPanel.onSelectTaskList = { [weak self] taskList in
            self?.panel?.showTaskDetail(taskList: taskList)
        }
        newPanel.onDeleteTaskList = { [weak self] taskList in
            self?.deleteTaskList(taskList)
        }
        newPanel.onToolSelected = { [weak self] tool in
            self?.panel?.pushToolView(tool: tool)
        }
        newPanel.onToolSearchChanged = { [weak self] query in
            let filtered = PanelToolRegistry.shared.search(query: query)
            self?.panel?.filterToolList(tools: filtered)
        }
        newPanel.onTaskSearchChanged = { [weak self] query in
            let groups = TaskStore.shared.searchGroupedByDate(query: query)
            self?.panel?.filterTaskList(
                groups: groups,
                emptyMessage: query.isEmpty
                    ? "No task lists yet. Ask Tama to create one for you."
                    : "No tasks found."
            )
        }
        newPanel.onSelectSkill = { [weak self] skill in
            self?.panel?.pushSkillView(skill: skill)
        }
        newPanel.onDeleteSkill = { [weak self] skill in
            self?.deleteSkill(skill)
        }
        newPanel.onSkillSearchChanged = { [weak self] query in
            let skills = SkillStore.shared.search(query: query)
            self?.panel?.filterSkillList(skills: skills)
        }
        newPanel.onSessionSearchChanged = { [weak self] query in
            guard let self else { return }
            let groups = SessionStore.shared.searchSessionsGroupedByDate(type: .reminders, query: query)
            let emptyMessage = query.isEmpty
                ? "No reminders yet. Ask Tama to set one for you."
                : "No reminders found."
            panel?.filterSessionList(groups: groups, emptyMessage: emptyMessage)
        }
        newPanel.onSelectRoutine = { [weak self] routine in
            self?.showRoutineDetail(routine)
        }
        newPanel.onDeleteRoutine = { [weak self] routine in
            self?.deleteRoutine(routine)
        }
        newPanel.onRunRoutine = { [weak self] routine in
            self?.runRoutine(routine)
        }
        newPanel.onRoutineSearchChanged = { [weak self] query in
            guard let self else { return }
            let routines = ScheduleStore.shared.jobs
                .filter { $0.jobType == .routine }
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            let emptyMessage = query.isEmpty
                ? "No routines yet. Ask Tama to create one for you."
                : "No routines found."
            panel?.filterRoutineList(routines: routines, emptyMessage: emptyMessage)
        }
        newPanel.onBackToList = { [weak self] in
            guard let self else { return }
            cancelAllActiveTasks()
            currentSession = nil
            conversationHistory = []
            handleTabChanged(currentTab)
            // Only start voice capture when returning to Chats tab
            if currentTab == .chats {
                startVoiceCapture()
            }
        }
        newPanel.onInterrupt = { [weak self] in
            guard let self else { return false }
            return interruptAgent()
        }
        newPanel.onDismiss = { [weak self] in
            guard let self else { return }
            isPanelDismissed = true

            // In voice mode, keep TTS streaming alive so the agent's response
            // plays as audio even after dismiss. The stream task is kept running
            // to await finishStreaming() and restart voice capture when done.
            if isVoiceMode, activeAgentTask != nil {
                logger.info("Voice mode dismiss — keeping TTS alive for background response")
                // Show notch activity indicator if agent is still working in the background.
                NotchActivityIndicator.addProcess(id: "chat-agent", label: "Thinking…")
                VoiceService.shared.stopFollowUpCapture()
                panel?.hideToolIndicator()
                panel?.hideThinkingIndicator()
                // Don't stop SpeechService, don't cancel stream task,
                // don't reset isVoiceMode — let voice continue in background
            } else {
                // Show activity indicator if agent is still working in the background.
                if activeAgentTask != nil {
                    NotchActivityIndicator.addProcess(id: "chat-agent", label: "Thinking…")
                }

                // Non-voice dismiss: cancel UI-only tasks but let agent keep running.
                activeStreamTask?.cancel()
                activeStreamTask = nil
                SpeechService.shared.shutdown()
                VoiceService.shared.stopFollowUpCapture()
                panel?.hideToolIndicator()
                panel?.hideThinkingIndicator()
                isVoiceMode = false

                // Schedule TTS engine unload after delay to free memory
                ttsUnloadTask?.cancel()
                ttsUnloadTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    KokoroManager.shared.unload()
                    self?.logger.info("TTS engine unloaded after idle timeout")
                }
            }
        }
        panel = newPanel
    }

    // MARK: - Interrupt

    /// Interrupts any active agent response, TTS, and voice capture.
    /// Returns true if something was interrupted, false if nothing was active.
    @discardableResult
    private func interruptAgent() -> Bool {
        let wasActive = (activeAgentTask != nil && !activeAgentTask!.isCancelled)
            || SpeechService.shared.isSpeaking

        cancelAllActiveTasks()
        panel?.mascot.setState(.idle)

        if wasActive {
            logger.info("Agent interrupted — ready for next prompt")
            startVoiceCapture()
        }

        return wasActive
    }

    // MARK: - Session Management

    /// Loads a saved session into the panel.
    private func loadSession(_ session: ChatSession) {
        logger.info("Loading session '\(session.title)' with \(session.messages.count) messages")
        currentSession = session

        // Rebuild conversationHistory from saved messages
        conversationHistory = session.messages.map { $0.toAPIFormat() }

        // Show the conversation in the panel
        panel?.restoreConversation(messages: session.messages)
    }

    /// Handles tab changes in the session list.
    private func handleTabChanged(_ tab: SessionTab) {
        let wasSearchTab = currentTab != .chats
        currentTab = tab

        // All non-chat tabs disable voice
        if tab != .chats {
            SpeechService.shared.stop()
            VoiceService.shared.stopFollowUpCapture()
            panel?.endVoiceSession()
            isVoiceMode = false
        }

        // Tools tab has its own display path
        if tab == .tools {
            panel?.hideSkillList()
            panel?.showToolList(tools: PanelToolRegistry.shared.allTools)
            return
        }

        // Tasks tab shows task lists
        if tab == .tasks {
            panel?.hideToolList()
            panel?.hideSkillList()
            let groups = TaskStore.shared.allTaskListsGroupedByDate()
            if groups.isEmpty {
                panel?.showTaskList([], emptyMessage: "No task lists yet. Ask Tama to create one for you.")
            } else {
                panel?.showTaskList(groups)
            }
            return
        }

        // Skills tab shows installed skills
        if tab == .skills {
            panel?.hideToolList()
            panel?.hideTaskList()
            SkillStore.shared.loadAll()
            let skills = SkillStore.shared.skills
            panel?.showSkillList(skills)
            return
        }

        // Hide tool list, task list, skill list, and routine list if switching away
        panel?.hideToolList()
        panel?.hideTaskList()
        panel?.hideSkillList()
        panel?.hideRoutineList()

        // Restart voice capture when returning to chats from a search tab
        if tab == .chats, wasSearchTab {
            startVoiceCapture()
        }

        // Routines tab shows scheduled routines (not session history)
        if tab == .routines {
            let routines = ScheduleStore.shared.jobs.filter { $0.jobType == .routine }
            if routines.isEmpty {
                panel?.showRoutineList([], emptyMessage: "No routines yet. Ask Tama to create one for you.")
            } else {
                panel?.showRoutineList(routines)
            }
            return
        }

        let (groups, emptyMessage, searchPlaceholder): (
            [(label: String, sessions: [ChatSession])], String, String?
        ) = switch tab {
        case .chats:
            (
                SessionStore.shared.allSessionsGroupedByDate(),
                "No conversations yet. Start chatting with Tama!",
                nil
            )
        case .reminders:
            (
                SessionStore.shared.sessionsGroupedByDate(type: .reminders),
                "No reminders yet. Ask Tama to set one for you.",
                "Search reminders..."
            )
        case .routines:
            ([], "", nil) // unreachable — handled above
        case .tasks, .tools, .skills:
            ([], "", nil) // unreachable — handled above
        }
        if groups.isEmpty {
            panel?.showSessionList([], emptyMessage: emptyMessage, searchPlaceholder: searchPlaceholder)
        } else {
            panel?.showSessionList(groups, searchPlaceholder: searchPlaceholder)
        }
    }

    /// Deletes a session and refreshes the list for the current tab.
    private func deleteSession(_ session: ChatSession) {
        logger.info("Deleting session '\(session.title)'")
        SessionStore.shared.delete(id: session.id)

        // If we're viewing this session, clear it
        if currentSession?.id == session.id {
            currentSession = nil
            conversationHistory = []
        }

        // Refresh the list for the current tab
        handleTabChanged(currentTab)
    }

    /// Deletes a task list and refreshes the task list view.
    private func deleteTaskList(_ taskList: TaskList) {
        logger.info("Deleting task list '\(taskList.title)'")
        TaskStore.shared.delete(id: taskList.id)
        // Refresh the task list
        handleTabChanged(currentTab)
    }

    /// Loads a skill into the conversation (for now just shows info).
    private func loadSkill(_ skill: Skill) {
        logger.info("Loading skill '\(skill.name)'")
        // For now, just start a new conversation with the skill content as context
        cancelAllActiveTasks(clearHistory: true)
        currentSession = nil

        // Add the skill content as a system-like context message
        let skillMessage = "Using skill: **\(skill.name)**\n\n\(skill.content)"
        conversationHistory = [
            ["role": "user", "content": "I'd like to use the \(skill.name) skill."],
            ["role": "assistant", "content": skillMessage],
        ]

        // Show in panel
        panel?.restoreConversation(messages: [
            ChatMessage(
                id: UUID(),
                role: .user,
                content: [.text("I'd like to use the \(skill.name) skill.")],
                timestamp: Date()
            ),
            ChatMessage(
                id: UUID(),
                role: .assistant,
                content: [.text(skillMessage)],
                timestamp: Date()
            ),
        ])
    }

    /// Deletes a skill and refreshes the skill list view.
    private func deleteSkill(_ skill: Skill) {
        logger.info("Deleting skill '\(skill.name)'")
        SkillStore.shared.delete(id: skill.id)
        // Refresh the skill list
        handleTabChanged(currentTab)
    }

    // MARK: - Routine Management

    /// Shows routine details in the conversation area like a chat session.
    /// Finds the most recent execution session for this routine, or shows just the prompt if never run.
    private func showRoutineDetail(_ routine: ScheduledJob) {
        logger.info("Showing routine '\(routine.name)' details")

        // Find the most recent session for this routine (by name match)
        let routineSessions = SessionStore.shared.sessions
            .filter { $0.sessionType == .routines && $0.title == routine.name }
            .sorted { $0.updatedAt > $1.updatedAt }

        if let mostRecentSession = routineSessions.first {
            // Show the actual conversation from the last execution
            panel?.restoreConversation(messages: mostRecentSession.messages)
        } else {
            // Never been run - show the prompt as a user message waiting to be executed
            let userMsg = ChatMessage(
                id: UUID(),
                role: .user,
                content: [.text(routine.prompt)],
                timestamp: Date()
            )
            let assistantMsg = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: [.text("Click **Run** to execute this routine. The result will appear here.")],
                timestamp: Date()
            )
            panel?.restoreConversation(messages: [userMsg, assistantMsg])
        }
    }

    private func formatDuration(seconds: Int) -> String {
        if seconds < 60 {
            "\(seconds) seconds"
        } else if seconds < 3600 {
            "\(seconds / 60) minutes"
        } else if seconds < 86400 {
            "\(seconds / 3600) hours"
        } else {
            "\(seconds / 86400) days"
        }
    }

    /// Deletes a routine and refreshes the routine list.
    private func deleteRoutine(_ routine: ScheduledJob) {
        logger.info("Deleting routine '\(routine.name)'")
        _ = ScheduleStore.shared.deleteJob(id: routine.id)
        // Refresh the routine list
        handleTabChanged(currentTab)
    }

    /// Runs a routine manually.
    private func runRoutine(_ routine: ScheduledJob) {
        logger.info("Manually running routine '\(routine.name)'")
        ScheduleStore.shared.runRoutineNow(id: routine.id)
        // Refresh the list to show shimmer effect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshRoutineListIfVisible()
        }
    }

    /// Refreshes the routine list if the panel is visible on the Routines tab.
    private func refreshRoutineListIfVisible() {
        guard currentTab == .routines, let panel, panel.isVisible, !isPanelDismissed else { return }
        let routines = ScheduleStore.shared.jobs.filter { $0.jobType == .routine }
        if routines.isEmpty {
            panel.showRoutineList([], emptyMessage: "No routines yet. Ask Tama to create one for you.")
        } else {
            panel.showRoutineList(routines)
        }
    }

    /// Saves the current conversation as a session.
    private func saveCurrentSession() {
        // Need at least one user message to save
        guard !conversationHistory.isEmpty else { return }

        let messages = conversationHistory.compactMap { ChatMessage.fromAPIFormat($0) }
        guard !messages.isEmpty else { return }

        if var session = currentSession {
            // Update existing session
            session.messages = messages
            session.updatedAt = Date()
            currentSession = session
            SessionStore.shared.save(session: session)
        } else {
            // Create new session
            let firstUserText = messages.first { $0.role == .user }?.content.compactMap { block -> String? in
                if case let .text(t) = block { return t }
                return nil
            }.joined() ?? "New conversation"

            let session = ChatSession(
                id: UUID(),
                title: ChatSession.generateTitle(from: firstUserText),
                messages: messages,
                createdAt: Date(),
                updatedAt: Date()
            )
            currentSession = session
            SessionStore.shared.save(session: session)
        }
    }

    // MARK: - Voice Capture

    /// Starts voice capture with waveform. User can speak or type — typing cancels voice.
    private func startVoiceCapture() {
        guard KokoroManager.shared.voiceEnabled else {
            logger.debug("Voice capture skipped — voice disabled")
            return
        }
        guard !isDismissedByAgent, !isPanelDismissed, let panel, panel.isVisible else {
            // swiftformat:disable:next redundantSelf
            let dismissed = self.isDismissedByAgent
            // swiftformat:disable:next redundantSelf
            let panelDismissed = self.isPanelDismissed
            // swiftformat:disable:next redundantSelf
            let panelVis = self.panel?.isVisible ?? false
            logger.debug(
                "Voice capture skipped — dismissed:\(dismissed) panelDismissed:\(panelDismissed) panelVisible:\(panelVis)"
            )
            return
        }
        SpeechService.shared.stop()
        isVoiceMode = true
        panel.showVoiceFollowUp()

        VoiceService.shared.onPartialTranscript = { [weak self] transcript in
            self?.panel?.hideSessionList()
            self?.panel?.insertVoiceText(transcript)
        }

        VoiceService.shared.onCaptureComplete = { [weak self] transcript in
            guard let self else { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            self.panel?.hideWaveform()

            if !trimmed.isEmpty {
                self.panel?.insertVoiceText(trimmed)
                handleSubmit(trimmed)
            }
            // isVoiceMode stays true — next ⌥Space will start voice again
        }

        VoiceService.shared.onAudioLevelChanged = { [weak self] level in
            self?.panel?.setAudioLevel(level)
        }

        VoiceService.shared.onError = { [weak self] errorMessage in
            self?.logger.warning("Voice capture error: \(errorMessage)")
            self?.panel?.hideWaveform()
            self?.isVoiceMode = false
            // Show subtle error — mic permission issues are common, don't alarm user
            self?.panel?.showError(title: "Voice", message: errorMessage, tint: .systemOrange)
        }

        VoiceService.shared.startFollowUpCapture()
        MenuBarMood.shared.setActivity(.listening)
    }

    // MARK: - Submit

    private func handleSubmit(_ text: String) {
        logger.info("handleSubmit — text length: \(text.count)")

        // Cancel any in-flight work before starting new ones.
        cancelAllActiveTasks()

        // Hide session list if visible
        panel?.hideSessionList()

        // Capture and clear input immediately so user can start typing next prompt
        let userText = panel?.consumeInput() ?? text

        guard ClaudeService.shared.isLoggedIn else {
            logger.warning("Submit attempted but not logged in")
            panel?.mascot.setState(.idle)
            MenuBarMood.shared.setActivity(.error)
            let err = AppError.notConnected
            panel?.showError(title: err.title, message: err.message, tint: err.tint)
            startVoiceCapture()
            return
        }

        // Only show generating indicator if we're actually going to generate a response
        panel?.showGeneratingIndicator()
        panel?.mascot.setState(.waiting)
        MenuBarMood.shared.setActivity(.thinking)

        let historyCountBeforeSubmit = conversationHistory.count
        conversationHistory.append(["role": "user", "content": userText])

        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self
        )

        let systemPrompt = isVoiceMode ? voiceSystemPrompt : agentSystemPrompt
        // swiftformat:disable:next redundantSelf
        logger.info("Using \(self.isVoiceMode ? "voice" : "typing") system prompt")

        // In voice mode, stop mic and start streaming TTS before the agent runs
        let speakInline = isVoiceMode
        if speakInline {
            VoiceService.shared.stopFollowUpCapture()
            panel?.hideWaveform()
        }

        // Save session early so it exists in the list and can show shimmer.
        saveCurrentSession()
        let capturedSessionId = currentSession!.id
        let capturedHistory = conversationHistory
        SessionStore.shared.markActive(capturedSessionId)

        activeAgentTask = Task { @MainActor [weak self] in
            // Always clean up active state and finish the continuation.
            defer {
                SessionStore.shared.markInactive(capturedSessionId)
                self?.refreshSessionListIfVisible()
                continuation.finish()
            }

            // Accumulate final response text so we can show a notification
            // if the panel was dismissed while the agent was working.
            nonisolated(unsafe) var backgroundAccumulatedText = ""

            do {
                try Task.checkCancellation()
                let updatedHistory = try await self?.agentLoop.run(
                    messages: capturedHistory,
                    systemPrompt: systemPrompt,
                    onEvent: { [weak self] event in
                        self?.handleAgentEvent(
                            event,
                            capturedSessionId: capturedSessionId,
                            speakInline: speakInline,
                            backgroundAccumulatedText: &backgroundAccumulatedText,
                            continuation: continuation
                        )
                    }
                )

                self?.activeAgentTask = nil
                self?.completeAgentRun(
                    updatedHistory: updatedHistory,
                    capturedSessionId: capturedSessionId,
                    backgroundAccumulatedText: backgroundAccumulatedText
                )
            } catch let error as AgentDismissError {
                // Save the conversation from the error before dismissing
                if let self {
                    conversationHistory = error.conversation
                    saveCurrentSession()
                }
                self?.handleAgentDismissed()
            } catch let error as AgentInterruptedError {
                // The loop failed mid-run (typically a transient network drop).
                // Persist the partial conversation — including any successful
                // tool calls — so the next prompt has full context instead of
                // starting blind.
                if let self {
                    self.completeAgentRun(
                        updatedHistory: error.conversation,
                        capturedSessionId: capturedSessionId,
                        backgroundAccumulatedText: backgroundAccumulatedText
                    )
                    self.logger
                        .error(
                            "Agent loop interrupted, persisted \(error.conversation.count) msgs: \(error.localizedDescription, privacy: .public)"
                        )
                }
                continuation.finish(throwing: error)
            } catch is CancellationError {
                self?.logger.info("Agent task cancelled")
            } catch let urlError as URLError where urlError.code == .cancelled {
                self?.logger.info("Agent task cancelled (URLSession)")
            } catch {
                guard !Task.isCancelled else {
                    self?.logger.info("Agent task cancelled (post-error)")
                    return
                }
                self?.logger.error("Agent loop error: \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
        }

        activeStreamTask = Task { @MainActor [weak self] in
            guard let self, let panel else { return }
            await handleStreamResponse(
                stream: stream,
                userText: userText,
                speakInline: speakInline,
                panel: panel,
                historyCountBeforeSubmit: historyCountBeforeSubmit
            )
            activeStreamTask = nil
        }
    }

    // MARK: - Stream Response Handling

    private func handleStreamResponse(
        stream: AsyncThrowingStream<String, Error>,
        userText: String,
        speakInline: Bool,
        panel: FloatingPanel,
        historyCountBeforeSubmit: Int
    ) async {
        if speakInline {
            SpeechService.shared.beginStreaming()
            MenuBarMood.shared.setActivity(.speaking)
        } else {
            MenuBarMood.shared.setActivity(.responding)
        }

        do {
            _ = try await panel.streamResponse(stream, userText: userText)
            if speakInline {
                await SpeechService.shared.finishStreaming()
                // If TTS finished while panel was dismissed (background voice),
                // schedule engine unload since we kept it alive for playback.
                if isPanelDismissed {
                    logger.info("Background voice playback finished")
                    isVoiceMode = false
                    MenuBarMood.shared.setActivity(nil)
                    ttsUnloadTask?.cancel()
                    ttsUnloadTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { return }
                        KokoroManager.shared.unload()
                        self?.logger.info("TTS engine unloaded after idle timeout")
                    }
                }
            }
            startVoiceCapture()
        } catch is CancellationError {
            logger.info("Stream task cancelled")
            if speakInline { SpeechService.shared.stop() }
            startVoiceCapture()
        } catch let urlError as URLError where urlError.code == .cancelled {
            logger.info("Stream task cancelled (URLSession)")
            if speakInline { SpeechService.shared.stop() }
            startVoiceCapture()
        } catch {
            // If this task was cancelled (e.g. user interrupted), don't
            // treat the error as real — a new submit may have already
            // appended to conversationHistory, so removeLast would
            // corrupt the wrong message.
            guard !Task.isCancelled else {
                logger.info("Stream task cancelled (post-error)")
                if speakInline { SpeechService.shared.stop() }
                return
            }
            logger.error("Stream response error: \(error.localizedDescription, privacy: .public)")
            // Restore history to the state before this submit to avoid
            // corrupting it (the agent may have already updated it).
            // Skip the rollback for AgentInterruptedError — the agent task
            // has intentionally persisted partial progress that we want to
            // keep so a follow-up prompt has full context.
            if !(error is AgentInterruptedError),
               conversationHistory.count > historyCountBeforeSubmit
            {
                conversationHistory.removeSubrange(historyCountBeforeSubmit...)
            }
            panel.hideToolIndicator()
            panel.hideThinkingIndicator()
            MenuBarMood.shared.setActivity(.error)
            let appError = AppError.from(error)
            panel.showError(
                title: appError.title,
                message: appError.message,
                tint: appError.tint
            )
            panel.mascot.setState(.idle)
            startVoiceCapture()
        }
    }

    // MARK: - Agent Event Handling

    /// Handles a single agent event and updates UI accordingly.
    private nonisolated func handleAgentEvent(
        _ event: AgentEvent,
        capturedSessionId: UUID,
        speakInline: Bool,
        backgroundAccumulatedText: inout String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        switch event {
        case let .textDelta(delta):
            backgroundAccumulatedText += delta
            MainActor.assumeIsolated {
                guard currentSession?.id == capturedSessionId else { return }
                if isPanelDismissed {
                    NotchActivityIndicator.updateDetail(id: "chat-agent", text: "Thinking…")
                }
                panel?.hideToolIndicator()
                if speakInline {
                    SpeechService.shared.feedChunk(delta)
                }
            }
            continuation.yield(delta)
        case let .toolStart(name, _):
            continuation.yield("\n\n")
            MainActor.assumeIsolated {
                guard currentSession?.id == capturedSessionId else { return }
                if isPanelDismissed {
                    let detail = ToolIndicatorView.displayName(for: name)
                    NotchActivityIndicator.updateDetail(id: "chat-agent", text: detail)
                }
                panel?.showToolIndicator(name: name)
                if speakInline {
                    SpeechService.shared.flushBuffer()
                }
            }
        case let .toolRunning(name, args):
            MainActor.assumeIsolated {
                guard currentSession?.id == capturedSessionId else { return }
                if isPanelDismissed {
                    let detail = ToolIndicatorView.displayName(for: name, args: args)
                    NotchActivityIndicator.updateDetail(id: "chat-agent", text: detail)
                }
                panel?.showToolIndicator(name: name, args: args)
            }
        case .toolResult:
            break
        case .turnComplete:
            MainActor.assumeIsolated {
                guard currentSession?.id == capturedSessionId else { return }
                panel?.hideToolIndicator()
            }
        case let .error(msg):
            MainActor.assumeIsolated {
                guard currentSession?.id == capturedSessionId else { return }
                panel?.hideToolIndicator()
            }
            continuation.yield("\n\n> **Error:** \(msg)\n\n")
        }
    }

    /// Completes an agent run, saving conversation and handling background notifications.
    private func completeAgentRun(
        updatedHistory: [[String: Any]]?,
        capturedSessionId: UUID,
        backgroundAccumulatedText: String
    ) {
        NotchActivityIndicator.removeProcess(id: "chat-agent")
        guard let updatedHistory else { return }

        let messages = updatedHistory.compactMap { ChatMessage.fromAPIFormat($0) }
        if !messages.isEmpty, var session = SessionStore.shared.session(for: capturedSessionId) {
            session.messages = messages
            session.updatedAt = Date()
            SessionStore.shared.save(session: session)
        }

        if currentSession?.id == capturedSessionId {
            conversationHistory = updatedHistory
            currentSession = SessionStore.shared.session(for: capturedSessionId)
        }

        logger.info("Agent finished — \(updatedHistory.count) messages saved to session")
        handleBackgroundReplyIfNeeded(
            backgroundAccumulatedText: backgroundAccumulatedText,
            capturedSessionId: capturedSessionId
        )
    }

    /// Shows a notification if the panel was dismissed while the agent was working.
    private func handleBackgroundReplyIfNeeded(backgroundAccumulatedText: String, capturedSessionId: UUID) {
        let isStillViewing = currentSession?.id == capturedSessionId && isPanelDismissed != true
        if isStillViewing { return }

        let reply = backgroundAccumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }

        logger.info("Panel dismissed — showing background reply notification")

        // Chat sessions open the panel with the session loaded on tap;
        // routines/reminders open the detail modal (default behavior).
        NotchNotificationPresenter.showAgentReply(message: reply) { [weak self] in
            guard let self,
                  let session = SessionStore.shared.session(for: capturedSessionId)
            else { return }
            openSession(session)
        }

        // System notification — include session ID so tapping it can also
        // open the correct session.
        let notificationId = capturedSessionId.uuidString
        Task {
            let content = UNMutableNotificationContent()
            content.title = "Tama"
            content.body = String(reply.prefix(256))
            content.sound = .default
            content.userInfo = ["sessionId": notificationId]
            let request = UNNotificationRequest(
                identifier: notificationId,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
        MenuBarMood.shared.setActivity(nil)
    }

    /// Opens the panel and loads the given session into the conversation view.
    /// Skips the session list display to avoid animation conflicts with restoreConversation.
    func openSession(_ session: ChatSession) {
        logger.info("Opening session from notification: '\(session.title)'")
        NotchActivityIndicator.removeProcess(id: "chat-agent")

        ttsUnloadTask?.cancel()
        ttsUnloadTask = nil

        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeAgentTask = nil
        SpeechService.shared.stop()
        VoiceService.shared.stopFollowUpCapture()
        panel?.hideToolIndicator()
        panel?.hideThinkingIndicator()
        MenuBarMood.shared.setActivity(nil)

        isDismissedByAgent = false
        isPanelDismissed = false
        isVoiceMode = false
        currentTab = .chats
        ensurePanel()
        conversationHistory = []
        panel?.present()

        // Make tab bar and divider visible — restoreConversation expects them
        // to already be showing (normally set by showSessionList).
        panel?.dividerContainer.isHidden = false
        panel?.dividerContainer.alphaValue = 1
        panel?.tabBarContainer.isHidden = false
        panel?.tabBarContainer.alphaValue = 1

        // Load session directly — no session list animation to conflict with.
        loadSession(session)

        // Start voice capture so the user can speak or type
        startVoiceCapture()
    }

    /// Handles the agent dismissing itself (user requested panel close).
    private func handleAgentDismissed() {
        logger.info("Agent dismissed — closing panel")
        NotchActivityIndicator.removeProcess(id: "chat-agent")
        isDismissedByAgent = true
        SpeechService.shared.stop()
        cancelAllActiveTasks(clearHistory: true)
        panel?.dismiss()
    }

    /// Refreshes the session list if the panel is visible and showing a list tab (not mid-conversation).
    private func refreshSessionListIfVisible() {
        guard let panel, panel.isVisible, !isPanelDismissed, !panel.isInsideSession else { return }
        handleTabChanged(currentTab)
    }

    // MARK: - System Prompts

    private var agentSystemPrompt: String {
        let cwd = Self.ensureWorkspace()
        let skillsSection = SkillStore.shared.formatForPrompt()
        return """
        You have access to tools for working with the user's computer. \
        You can run shell commands (bash), read/write/edit files, \
        search code (grep/find), list directories (ls), fetch web \
        pages (web_fetch), and search the web (web_search). \
        You can also create reminders (create_reminder) and \
        routines (create_routine) that run on a schedule, list them \
        (list_schedules), and delete them (delete_schedule). \
        Reminders fire macOS notifications; routines run an LLM prompt \
        and notify with the result. \
        For multi-step tasks, use the "task" tool to create a checklist — \
        tasks are stored and run later when the user opens the Tasks Pane (⌥Space → Tasks tab) \
        and presses R. Working directory: \(cwd)
        \(skillsSection)
        """
    }

    private var voiceSystemPrompt: String {
        let cwd = Self.ensureWorkspace()
        let skillsSection = SkillStore.shared.formatForPrompt()
        return """
        You have access to tools for working with the user's computer. \
        You can run shell commands (bash), read/write/edit files, \
        search code (grep/find), list directories (ls), fetch web \
        pages (web_fetch), search the web (web_search), create \
        reminders (create_reminder — fires a notification), routines \
        (create_routine — runs a prompt and notifies), list/delete \
        schedules, and create task checklists (task — stored for later). \
        Working directory: \(cwd)
        \(skillsSection)

        CRITICAL: This is a live voice conversation. You are talking to a real person, out loud, \
        in real time. Their mic is on, your voice is playing through their speakers. \
        This is a phone call, not a chat window.

        The most important thing: THERE SHOULD NEVER BE SILENCE. \
        In a real conversation between two people, one person talks, then the other responds \
        immediately. No dead air. No awkward pauses. That's how you need to operate. \
        The moment you receive their words, you respond — and if you need to go do something \
        (search the web, read a file, run a command), you TELL them first, naturally, \
        the way a person would: "Oh yeah hang on, let me look that up..." or \
        "Gimme a sec, pulling that up now." Then do your thing. Then come back and tell them what you found. \
        The user should always hear your voice, never just silence.

        Length: match the question. "What's up" = one sentence. \
        "Give me all the AI news" = as long as it needs to be. \
        But never pad or ramble. Every sentence earns its place.

        Be natural. Use contractions, react to what they say, laugh if something's funny, \
        acknowledge if they're frustrated. You're not an assistant reading a script — \
        you're a person they know, on a call.

        Hard rules:
        - No markdown, no bullet points, no code blocks. Plain spoken words only.
        - For tool results, just say what happened. "Done." or "Yeah that file's updated."
        - Don't repeat their question back to them.

        """
    }

    // MARK: - Carbon Hot Key

    private func registerCarbonHotKey(keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(
            signature: fourCharCode("TGCH"),
            id: 1
        )

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in
                    PromptPanelController.shared.toggle()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        guard handlerResult == noErr else {
            logger.error("Failed to install hotkey handler")
            return
        }

        let registerResult = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerResult != noErr {
            logger.error("Failed to register hotkey")
        }
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}
