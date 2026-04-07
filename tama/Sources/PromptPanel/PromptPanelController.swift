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

    /// Returns ~/Documents/Tama, creating it (and the Screenshots subdirectory) if needed.
    private static func ensureWorkspace() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let workspace = docs.appendingPathComponent("Tama")
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Tama/Screenshots").path
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
        MenuBarMood.shared.setActivity(nil)

        isDismissedByAgent = false
        isPanelDismissed = false
        currentSession = nil
        currentTab = .chats
        ensurePanel()
        conversationHistory = []
        panel?.present()

        // Show recent sessions if any exist
        SessionStore.shared.loadAll()
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
        activeAgentTask?.cancel()
        activeStreamTask?.cancel()
        activeAgentTask = nil
        activeStreamTask = nil
        SpeechService.shared.stop()
        VoiceService.shared.stopFollowUpCapture()
        BrowserManager.shared.disconnect()
        panel?.hideToolIndicator()
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
                // User started typing — cancel voice capture & speech, switch to typing mode
                if VoiceService.shared.state == .followUp {
                    logger.info("User typing — cancelling voice capture")
                    SpeechService.shared.stop()
                    VoiceService.shared.stopFollowUpCapture()
                    newPanel.hideWaveformForTyping()
                    isVoiceMode = false
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
        newPanel.onSessionSearchChanged = { [weak self] query in
            guard let self else { return }
            let type: SessionType = currentTab == .reminders ? .reminders : .routines
            let groups = SessionStore.shared.searchSessionsGroupedByDate(type: type, query: query)
            let emptyMessage = query.isEmpty
                ? (type == .reminders
                    ? "No reminders yet. Ask Tama to set one for you."
                    : "No routines yet. Ask Tama to create one for you.")
                : "No \(type.rawValue) found."
            panel?.filterSessionList(groups: groups, emptyMessage: emptyMessage)
        }
        newPanel.onBackToList = { [weak self] in
            guard let self else { return }
            cancelAllActiveTasks()
            currentSession = nil
            conversationHistory = []
            handleTabChanged(currentTab)
            startVoiceCapture()
        }
        newPanel.onInterrupt = { [weak self] in
            guard let self else { return false }
            return interruptAgent()
        }
        newPanel.onDismiss = { [weak self] in
            guard let self else { return }
            isPanelDismissed = true

            // Cancel UI-only tasks (stream rendering, TTS, voice) but
            // let the agent task keep running in the background so the
            // LLM call completes and the user gets a notification.
            activeStreamTask?.cancel()
            activeStreamTask = nil
            SpeechService.shared.stop()
            VoiceService.shared.stopFollowUpCapture()
            panel?.hideToolIndicator()
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
            panel?.showToolList(tools: PanelToolRegistry.shared.allTools)
            return
        }

        // Tasks tab shows task lists
        if tab == .tasks {
            panel?.hideToolList()
            let groups = TaskStore.shared.allTaskListsGroupedByDate()
            if groups.isEmpty {
                panel?.showTaskList([], emptyMessage: "No task lists yet. Ask Tama to create one for you.")
            } else {
                panel?.showTaskList(groups)
            }
            return
        }

        // Hide tool list and task list if switching away
        panel?.hideToolList()
        panel?.hideTaskList()

        // Restart voice capture when returning to chats from a search tab
        if tab == .chats, wasSearchTab {
            startVoiceCapture()
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
            (
                SessionStore.shared.sessionsGroupedByDate(type: .routines),
                "No routines yet. Ask Tama to create one for you.",
                "Search routines..."
            )
        case .tasks, .tools:
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
        guard !isDismissedByAgent, !isPanelDismissed, let panel, panel.isVisible else { return }
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

        panel?.mascot.setState(.waiting)
        MenuBarMood.shared.setActivity(.thinking)

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

                self?.completeAgentRun(
                    updatedHistory: updatedHistory,
                    capturedSessionId: capturedSessionId,
                    backgroundAccumulatedText: backgroundAccumulatedText
                )
            } catch is AgentDismissError {
                self?.handleAgentDismissed()
            } catch is CancellationError {
                self?.logger.info("Agent task cancelled")
            } catch let urlError as URLError where urlError.code == .cancelled {
                self?.logger.info("Agent task cancelled (URLSession)")
            } catch {
                guard !Task.isCancelled else {
                    self?.logger.info("Agent task cancelled (post-error)")
                    return
                }
                self?.logger.error("Agent loop error: \(error.localizedDescription)")
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
            logger.error("Stream response error: \(error.localizedDescription)")
            // Restore history to the state before this submit to avoid
            // corrupting it (the agent may have already updated it).
            if conversationHistory.count > historyCountBeforeSubmit {
                conversationHistory.removeSubrange(historyCountBeforeSubmit...)
            }
            panel.hideToolIndicator()
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
                panel?.showToolIndicator(name: name)
                if speakInline {
                    SpeechService.shared.flushBuffer()
                }
            }
        case let .toolRunning(name, args):
            MainActor.assumeIsolated {
                guard currentSession?.id == capturedSessionId else { return }
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
        NotchNotificationPresenter.showAgentReply(message: reply)

        Task {
            let content = UNMutableNotificationContent()
            content.title = "Tama"
            content.body = String(reply.prefix(256))
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
        MenuBarMood.shared.setActivity(nil)
    }

    /// Handles the agent dismissing itself (user requested panel close).
    private func handleAgentDismissed() {
        logger.info("Agent dismissed — closing panel")
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
        return """
        you have access to tools for working with the user's computer. \
        you can run shell commands (bash), read/write/edit files, \
        search code (grep/find), list directories (ls), fetch web \
        pages (web_fetch), and search the web (web_search). \
        you can also create reminders (create_reminder) and \
        routines (create_routine) that run on a schedule, list them \
        (list_schedules), and delete them (delete_schedule). \
        reminders fire macOS notifications; routines run an LLM prompt \
        and notify with the result. \
        for multi-step tasks, use the "task" tool to create a checklist — \
        tasks are stored and run later when the user opens the Tasks Pane (⌥Space → Tasks tab) \
        and presses R. working directory: \(cwd)
        """
    }

    private var voiceSystemPrompt: String {
        let cwd = Self.ensureWorkspace()
        return """
        you have access to tools for working with the user's computer. \
        you can run shell commands (bash), read/write/edit files, \
        search code (grep/find), list directories (ls), fetch web \
        pages (web_fetch), search the web (web_search), create \
        reminders (create_reminder — fires a notification), routines \
        (create_routine — runs a prompt and notifies), list/delete \
        schedules, and create task checklists (task — stored for later). \
        working directory: \(cwd)

        CRITICAL: this is a voice conversation. your response will be spoken aloud. \
        you MUST be extremely brief:

        - answer in ONE sentence when possible. never exceed two sentences unless \
        the user explicitly asks you to explain in detail.
        - use proper grammar and punctuation. write naturally as if speaking.
        - absolutely no markdown, no bullet points, no code blocks, no headers. \
        plain text only.
        - for tool results: say what happened in a few words. \
        "Done." or "I've updated that file." or "There are 12 files." — that's it.
        - do not repeat the user's question back to them. do not add pleasantries \
        like "Sure!" or "Of course!" — just answer directly.
        - if the user asks something complex, give the short answer first, \
        then ask if they want more detail.
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
