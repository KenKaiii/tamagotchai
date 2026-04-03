import AppKit
import Carbon.HIToolbox
import os

/// Manages the floating prompt panel lifecycle and global hotkey registration.
@MainActor
final class PromptPanelController {
    static let shared = PromptPanelController()
    private let logger = Logger(subsystem: "com.unstablemind.tamagotchai", category: "controller")

    private var panel: FloatingPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var conversationHistory: [[String: Any]] = []
    private var isVoiceMode = false
    private var activeAgentTask: Task<Void, Never>?
    private var activeStreamTask: Task<Void, Never>?
    private lazy var agentLoop = AgentLoop(
        workingDirectory: Self.ensureWorkspace()
    )

    /// Returns ~/Documents/Tamagotchai, creating it if needed.
    private static func ensureWorkspace() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let workspace = docs.appendingPathComponent("Tamagotchai")
        if !FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }
        return workspace.path
    }

    // MARK: - Public

    /// Registers the global hotkey.
    func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey)
    ) {
        registerCarbonHotKey(keyCode: keyCode, modifiers: modifiers)
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

        // Hard reset: kill any in-flight work from the previous session.
        // This guarantees a clean slate even if the previous agent hung or errored.
        cancelAllActiveTasks()

        ensurePanel()
        conversationHistory = []
        panel?.present()

        // Start voice capture alongside typing — user decides by their action
        startVoiceCapture()
    }

    /// Cancels and nils all active tasks, stops TTS and voice capture,
    /// and resets the tool indicator. Safe to call even if nothing is active.
    private func cancelAllActiveTasks() {
        activeAgentTask?.cancel()
        activeStreamTask?.cancel()
        activeAgentTask = nil
        activeStreamTask = nil
        SpeechService.shared.stop()
        VoiceService.shared.stopFollowUpCapture()
        panel?.hideToolIndicator()
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
            } else {
                newPanel.mascot.notifyKeystroke()
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
        newPanel.onInterrupt = { [weak self] in
            guard let self else { return false }
            return interruptAgent()
        }
        newPanel.onDismiss = { [weak self] in
            guard let self else { return }
            cancelAllActiveTasks()
            isVoiceMode = false
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

    // MARK: - Voice Capture

    /// Starts voice capture with waveform. User can speak or type — typing cancels voice.
    private func startVoiceCapture() {
        SpeechService.shared.stop()
        isVoiceMode = true
        panel?.showVoiceFollowUp()

        VoiceService.shared.onPartialTranscript = { [weak self] transcript in
            self?.panel?.insertVoiceText(transcript)
        }

        VoiceService.shared.onCaptureComplete = { [weak self] transcript in
            guard let self else { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            panel?.hideWaveform()

            if !trimmed.isEmpty {
                panel?.insertVoiceText(trimmed)
                handleSubmit(trimmed)
            }
            // isVoiceMode stays true — next ⌥Space will start voice again
        }

        VoiceService.shared.onAudioLevelChanged = { [weak self] level in
            self?.panel?.setAudioLevel(level)
        }

        VoiceService.shared.startFollowUpCapture()
    }

    // MARK: - Submit

    private func handleSubmit(_ text: String) {
        logger.info("handleSubmit — text length: \(text.count)")

        // Cancel any in-flight work before starting new ones.
        cancelAllActiveTasks()

        panel?.mascot.setState(.waiting)

        // Capture and clear input immediately so user can start typing next prompt
        let userText = panel?.consumeInput() ?? text

        guard ClaudeService.shared.isLoggedIn else {
            logger.warning("Submit attempted but not logged in")
            panel?.mascot.setState(.idle)
            panel?.showResponse(
                "Not logged in to Claude. Use the menu bar → Login to Claude."
            )
            return
        }

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

        activeAgentTask = Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }

            // Guarantee the continuation is finished on ALL exit paths.
            // Without this, streamResponse hangs forever on the for-await loop
            // if an unexpected code path skips continuation.finish().
            defer { continuation.finish() }

            do {
                try Task.checkCancellation()
                let updatedHistory = try await agentLoop.run(
                    messages: conversationHistory,
                    systemPrompt: systemPrompt,
                    onEvent: { [weak self] event in
                        switch event {
                        case let .textDelta(delta):
                            DispatchQueue.main.async {
                                self?.panel?.hideToolIndicator()
                                if speakInline {
                                    SpeechService.shared.feedChunk(delta)
                                }
                            }
                            continuation.yield(delta)
                        case let .toolStart(name, _):
                            continuation.yield("\n\n")
                            DispatchQueue.main.async {
                                self?.panel?.showToolIndicator(name: name)
                                if speakInline {
                                    SpeechService.shared.flushBuffer()
                                }
                            }
                        case .toolResult:
                            break
                        case .turnComplete:
                            DispatchQueue.main.async {
                                self?.panel?.hideToolIndicator()
                            }
                        // continuation.finish() handled by defer
                        case let .error(msg):
                            DispatchQueue.main.async {
                                self?.panel?.hideToolIndicator()
                            }
                            continuation.yield("\n⚠️ \(msg)\n")
                        }
                    }
                )
                conversationHistory = updatedHistory
                // swiftformat:disable:next redundantSelf
                logger.info("Conversation history updated — \(self.conversationHistory.count) messages")
            } catch is CancellationError {
                logger.info("Agent task cancelled")
            } catch {
                logger.error("Agent loop error: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }

        activeStreamTask = Task { @MainActor [weak self] in
            guard let self, let panel else { return }

            // Start streaming TTS session so sentences are spoken as they arrive
            if speakInline {
                SpeechService.shared.beginStreaming()
            }

            do {
                _ = try await panel.streamResponse(stream, userText: userText)

                if speakInline {
                    await SpeechService.shared.finishStreaming()
                }

                // Restart voice capture for next prompt
                startVoiceCapture()
            } catch is CancellationError {
                logger.info("Stream task cancelled")
                if speakInline {
                    SpeechService.shared.stop()
                }
                startVoiceCapture()
            } catch {
                logger.error("Stream response error: \(error.localizedDescription)")
                conversationHistory.removeLast()
                panel.hideToolIndicator()
                panel.showResponse(
                    "Error: \(error.localizedDescription)"
                )
                panel.mascot.setState(.idle)
                startVoiceCapture()
            }

            activeAgentTask = nil
            activeStreamTask = nil
        }
    }

    // MARK: - System Prompts

    private var agentSystemPrompt: String {
        let cwd = Self.ensureWorkspace()
        return """
        you have access to tools for working with the user's computer. \
        you can run shell commands (bash), read/write/edit files, \
        search code (grep/find), list directories (ls), and fetch web \
        pages. working directory: \(cwd)
        """
    }

    private var voiceSystemPrompt: String {
        let cwd = Self.ensureWorkspace()
        return """
        you have access to tools for working with the user's computer. \
        you can run shell commands (bash), read/write/edit files, \
        search code (grep/find), list directories (ls), and fetch web \
        pages. working directory: \(cwd)

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
