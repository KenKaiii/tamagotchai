import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "callsession"
)

/// Manages the full lifecycle of a voice call via the notch.
///
/// Owns an `AgentLoop`, conversation history, voice capture callbacks,
/// TTS streaming, and interrupt detection. The entire interaction happens
/// through voice — no chat UI is opened.
///
/// Flow: greeting → listen (VP+muted) → agent+TTS (VP, no mute, interrupt detection) → …
///
/// Uses Apple Voice Processing IO (AEC) on the mic so the speech recognizer
/// doesn't pick up TTS audio playing through the speakers. This enables
/// interrupt detection during TTS playback without false triggers.
@MainActor
final class CallSession {
    // MARK: - State

    private var conversationHistory: [[String: Any]] = []
    private var chatSession: ChatSession?
    private let agentLoop = AgentLoop(registry: ToolRegistry.callRegistry())
    private var agentTask: Task<Void, Never>?
    private var isListening = false
    private var isResponding = false
    private var isActive = false

    /// Per-turn telemetry — user speech timing, agent TTFB, TTS latency,
    /// dead-air detection. Summary printed to the `callmetrics` log category
    /// at the end of each turn.
    private let metrics = CallMetrics()
    /// Last tool name emitted by the agent, so we can record its duration when
    /// the matching `.toolResult` event arrives.
    private var pendingToolName: String?
    private var pendingToolStart: CFAbsoluteTime?

    // NOTE: Interrupt detection is intentionally disabled. On macOS without headphones,
    // AVAudioEngine VP is too aggressive (silences user voice too), and without VP the
    // speech recognizer doesn't produce reliable transcripts during TTS playback.
    // Proper interrupt detection requires a shared AVAudioEngine for mic + playback
    // with VP on both input and output nodes (see SwiftOpenAI, Litter patterns).
    // For now we use clean alternation: listen → respond → listen.

    // MARK: - Public API

    /// Greetings rotated at the start of each call so every call doesn't
    /// open with the same line. Kept short so TTS time-to-first-audio stays low.
    private static let greetings = [
        "Hey, what's up?",
        "Yo, what can I do for you?",
        "Hey, what's on your mind?",
        "What's up, what do you need?",
        "Hey, I'm here — what's going on?",
        "Yo, talk to me.",
        "Hey hey, what can I help with?",
    ]

    /// Starts the voice call — speaks a greeting, then begins listening.
    ///
    /// Pre-warms the provider HTTP connection and Kokoro TTS engine while the
    /// greeting plays so the first real user turn pays zero cold-start cost.
    /// Both pre-warms are fire-and-forget — failures are non-fatal.
    func start() {
        guard !isActive else {
            logger.warning("start() called but already active — ignoring")
            return
        }
        logger.info("━━━ CALL SESSION START ━━━")
        isActive = true
        installMetricsHooks()

        // Fire pre-warms immediately, before anything blocking. The TLS
        // handshake and Kokoro graph build overlap with the greeting TTS so
        // by the time the user finishes speaking, both are ready.
        ClaudeService.shared.prewarmConnection(for: ProviderStore.shared.selectedModel.provider)
        KokoroManager.shared.prewarm()

        let session = ChatSession(
            id: UUID(),
            title: "Voice Call",
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            sessionType: .chat
        )
        chatSession = session
        SessionStore.shared.save(session: session)
        logger.info("Created chat session: \(session.id.uuidString)")

        setupVoiceCallbacks()
        speakGreeting()
    }

    /// Speaks a greeting via TTS, then starts listening once it finishes.
    ///
    /// While the greeting plays, the mic capture engine is prewarmed with
    /// Voice Processing enabled. VP needs ~1s of real audio to adapt its AEC
    /// — without this warm-up the first user utterance after the greeting
    /// gets aggressively gated, making the mic feel unresponsive for 1–2s
    /// even though the waveform UI is already live.
    private func speakGreeting() {
        let greeting = Self.greetings.randomElement() ?? "Hey, what's up?"
        logger.info("[GREETING] Speaking: \"\(greeting)\"")

        // Show grey (responding) bars while the agent speaks the greeting.
        // Default is .listening (green), which would misrepresent the state.
        NotchCallTimer.setMode(.responding)
        NotchCallTimer.setAudioLevel(0)

        SpeechService.shared.beginStreaming()
        SpeechService.shared.feedChunk(greeting)

        // Kick off mic prewarm in parallel with the greeting TTS. No mute —
        // the greeting needs to be audible, and VP uses the speaker output as
        // its reference signal to adapt the AEC. Deferred to the next runloop
        // tick so the call-button UI transition renders first — AVAudioEngine
        // start + setVoiceProcessingEnabled can block ~100–500ms on main.
        Task { @MainActor in
            VoiceService.shared.prewarmCapture(voiceProcessing: true)
        }

        Task { @MainActor [weak self] in
            await SpeechService.shared.finishStreaming()
            logger.info("[GREETING] TTS finished")
            guard let self, isActive else { return }
            startListening()
        }
    }

    /// Ends the voice call — stops everything, saves the session.
    func end() {
        guard isActive else {
            logger.warning("end() called but not active — ignoring")
            return
        }
        logger.info("━━━ CALL SESSION END ━━━")
        isActive = false

        agentTask?.cancel()
        agentTask = nil

        SpeechService.shared.stop()
        VoiceService.shared.stopFollowUpCapture()

        isListening = false
        isResponding = false

        clearVoiceCallbacks()
        clearMetricsHooks()
        saveSession()

        // swiftformat:disable:next redundantSelf
        logger.info("[END] Done — \(self.conversationHistory.count) messages")
    }

    // MARK: - Voice Capture

    private func setupVoiceCallbacks() {
        let voice = VoiceService.shared

        voice.onCaptureComplete = { [weak self] text in
            logger.info("[VOICE] onCaptureComplete — length=\(text.count)")
            Task { @MainActor [weak self] in
                self?.handleCaptureComplete(text)
            }
        }

        voice.onPartialTranscript = { partial in
            logger.debug("[VOICE] partial: \"\(partial.prefix(60))\"")
        }

        voice.onAudioLevelChanged = { level in
            NotchCallTimer.setAudioLevel(level)
        }

        voice.onError = { errorMessage in
            logger.error("[VOICE] Error: \(errorMessage)")
        }
    }

    private func clearVoiceCallbacks() {
        let voice = VoiceService.shared
        voice.onCaptureComplete = nil
        voice.onPartialTranscript = nil
        voice.onAudioLevelChanged = nil
        voice.onError = nil
    }

    /// Start listening for user speech.
    /// Uses `voiceProcessing: true` for AEC + `muteAudio: true` so the mic
    /// only hears the user (system audio muted, AEC removes any residual).
    /// Silence window is shorter than default for snappy turn-taking.
    private func startListening() {
        guard isActive else { return }
        logger.info("[LISTEN] ▶ Listening (VP + muted, 0.6s silence)")
        isListening = true
        isResponding = false
        NotchCallTimer.setMode(.listening)
        metrics.beginTurn()

        VoiceService.shared.startFollowUpCapture(
            muteAudio: true,
            voiceProcessing: true,
            silenceDuration: 0.6
        )
    }

    // MARK: - Metrics Wiring

    /// Installs telemetry callbacks on VoiceService and SpeechService so the
    /// CallMetrics accumulator can record each phase's timing. Installed once
    /// per call start; cleared in `end()`.
    private func installMetricsHooks() {
        VoiceService.shared.onFirstSpeech = { [weak self] in
            Task { @MainActor [weak self] in
                self?.metrics.noteFirstSpeech()
            }
        }
        SpeechService.shared.onFirstChunkEnqueued = { [weak self] in
            self?.metrics.noteFirstTTSEnqueue()
        }
        SpeechService.shared.onFirstAudioReady = { [weak self] in
            self?.metrics.noteFirstAudioReady()
        }
        SpeechService.shared.onFirstAudioPlayback = { [weak self] in
            self?.metrics.noteFirstAudioPlayback()
        }
        SpeechService.shared.onPlaybackGap = { [weak self] gap in
            self?.metrics.notePlaybackGap(gap)
        }
    }

    private func clearMetricsHooks() {
        VoiceService.shared.onFirstSpeech = nil
        SpeechService.shared.onFirstChunkEnqueued = nil
        SpeechService.shared.onFirstAudioReady = nil
        SpeechService.shared.onFirstAudioPlayback = nil
        SpeechService.shared.onPlaybackGap = nil
    }

    // MARK: - Speech Handling

    private func handleCaptureComplete(_ text: String) {
        guard isActive else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0.isWhitespace }.count
        logger.info("[SPEECH] Received — \(words) words, \(trimmed.count) chars")
        metrics.noteSilenceDetected(wordCount: words)

        guard !trimmed.isEmpty else {
            logger.info("[SPEECH] Empty transcript — restarting listening")
            startListening()
            return
        }

        logger.info("[SPEECH] ✦ User said: \"\(trimmed.prefix(120))\"")
        isListening = false

        conversationHistory.append(["role": "user", "content": trimmed])
        // swiftformat:disable:next redundantSelf
        logger.info("[SPEECH] History: \(self.conversationHistory.count) messages")

        if conversationHistory.count == 1 {
            let title = ChatSession.generateTitle(from: trimmed)
            chatSession?.title = title
        }

        runAgent()
    }

    // MARK: - Agent

    private func runAgent() {
        guard isActive else { return }
        logger.info("[AGENT] ▶ Starting agent run")
        isResponding = true
        NotchCallTimer.setMode(.responding)
        NotchCallTimer.setAudioLevel(0)

        SpeechService.shared.beginStreaming()
        metrics.noteAgentRequestSent()

        let messages = conversationHistory
        logger.info("[AGENT] Sending \(messages.count) messages")

        agentTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let updatedHistory = try await agentLoop.run(
                    messages: messages,
                    systemPrompt: buildCallSystemPrompt(),
                    useBasePrompt: false,
                    maxTokens: 300,
                    onEvent: { [weak self] event in
                        MainActor.assumeIsolated {
                            self?.handleAgentEvent(event)
                        }
                    }
                )

                logger.info("[AGENT] Done — \(updatedHistory.count) messages")
                conversationHistory = updatedHistory

                // Always save the conversation, even if the call ended while the agent was running.
                // This ensures the session has all messages when viewed later.
                guard isActive else {
                    saveSession()
                    return
                }

                logger.info("[AGENT] Waiting for TTS...")
                await SpeechService.shared.finishStreaming()
                logger.info("[AGENT] TTS finished")
                metrics.noteTTSFinished()
                metrics.endTurn()

                guard isActive else {
                    saveSession()
                    return
                }
                isResponding = false
                saveSession()

                // Start listening for next utterance
                startListening()
            } catch let error as AgentEndCallError {
                logger.info("[AGENT] End call requested — finishing TTS then hanging up")
                NotchActivityIndicator.removeProcess(id: "call-agent")
                conversationHistory = error.conversation
                await SpeechService.shared.finishStreaming()
                metrics.noteTTSFinished()
                metrics.endTurn()
                saveSession()
                // End the call via NotchCallButton (updates UI + calls self.end())
                NotchCallButton.endCall()
            } catch is CancellationError {
                logger.info("[AGENT] Cancelled")
                NotchActivityIndicator.removeProcess(id: "call-agent")
            } catch let error as AgentDismissError {
                logger.info("[AGENT] Dismissed")
                NotchActivityIndicator.removeProcess(id: "call-agent")
                conversationHistory = error.conversation
                saveSession()
            } catch let urlError as URLError where urlError.code == .cancelled {
                logger.info("[AGENT] Cancelled (URLSession)")
                NotchActivityIndicator.removeProcess(id: "call-agent")
            } catch {
                guard !Task.isCancelled else {
                    logger.info("[AGENT] Cancelled (post-error)")
                    NotchActivityIndicator.removeProcess(id: "call-agent")
                    return
                }
                logger.error("[AGENT] ✗ Error: \(error.localizedDescription)")
                NotchActivityIndicator.removeProcess(id: "call-agent")
                isResponding = false
                SpeechService.shared.stop()
                startListening()
            }
        }
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        guard isActive else { return }
        switch event {
        case let .textDelta(delta):
            metrics.noteFirstDelta(delta)
            SpeechService.shared.feedChunk(delta)
            NotchActivityIndicator.removeProcess(id: "call-agent")
        case let .toolStart(name, id):
            logger.info("[EVENT] toolStart: \(name) (id=\(id))")
            pendingToolName = name
            pendingToolStart = CFAbsoluteTimeGetCurrent()
            SpeechService.shared.flushBuffer()
            let detail = ToolIndicatorView.displayName(for: name)
            NotchActivityIndicator.addProcess(id: "call-agent", label: detail)
        case let .toolRunning(name, args):
            let detail = ToolIndicatorView.displayName(for: name, args: args)
            NotchActivityIndicator.updateDetail(id: "call-agent", text: detail)
        case let .toolResult(name, _):
            if let start = pendingToolStart, pendingToolName == name {
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                metrics.noteToolComplete(name: name, durationMs: ms)
            }
            pendingToolName = nil
            pendingToolStart = nil
            NotchActivityIndicator.removeProcess(id: "call-agent")
        case let .turnComplete(text):
            logger.info("[EVENT] turnComplete — \(text.count) chars")
            NotchActivityIndicator.removeProcess(id: "call-agent")
        case let .error(msg):
            logger.error("[EVENT] ✗ error: \(msg)")
            NotchActivityIndicator.removeProcess(id: "call-agent")
        }
    }

    // MARK: - Session Persistence

    private func saveSession() {
        guard var session = chatSession else { return }
        let messages = conversationHistory.compactMap { ChatMessage.fromAPIFormat($0) }
        session.messages = messages
        session.updatedAt = Date()
        chatSession = session
        SessionStore.shared.save(session: session)
        logger.info("[SAVE] Saved — \(messages.count) messages")
    }
}
