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

    // NOTE: Interrupt detection is intentionally disabled. On macOS without headphones,
    // AVAudioEngine VP is too aggressive (silences user voice too), and without VP the
    // speech recognizer doesn't produce reliable transcripts during TTS playback.
    // Proper interrupt detection requires a shared AVAudioEngine for mic + playback
    // with VP on both input and output nodes (see SwiftOpenAI, Litter patterns).
    // For now we use clean alternation: listen → respond → listen.

    // MARK: - Public API

    /// Greeting spoken at the start of every call.
    private static let greeting = "Hey, what can I help you with today?"

    /// Starts the voice call — speaks a greeting, then begins listening.
    func start() {
        guard !isActive else {
            logger.warning("start() called but already active — ignoring")
            return
        }
        logger.info("━━━ CALL SESSION START ━━━")
        isActive = true

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
    private func speakGreeting() {
        let greeting = Self.greeting
        logger.info("[GREETING] Speaking: \"\(greeting)\"")

        SpeechService.shared.beginStreaming()
        SpeechService.shared.feedChunk(greeting)

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

        VoiceService.shared.startFollowUpCapture(
            muteAudio: true,
            voiceProcessing: true,
            silenceDuration: 0.6
        )
    }

    // MARK: - Speech Handling

    private func handleCaptureComplete(_ text: String) {
        guard isActive else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("[SPEECH] Received — length=\(trimmed.count)")

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

        let messages = conversationHistory
        logger.info("[AGENT] Sending \(messages.count) messages")

        agentTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let updatedHistory = try await agentLoop.run(
                    messages: messages,
                    systemPrompt: buildCallSystemPrompt(),
                    maxTokens: 300,
                    onEvent: { [weak self] event in
                        MainActor.assumeIsolated {
                            self?.handleAgentEvent(event)
                        }
                    }
                )

                logger.info("[AGENT] Done — \(updatedHistory.count) messages")
                guard isActive else { return }
                conversationHistory = updatedHistory

                logger.info("[AGENT] Waiting for TTS...")
                await SpeechService.shared.finishStreaming()
                logger.info("[AGENT] TTS finished")

                guard isActive else { return }
                isResponding = false
                saveSession()

                // Start listening for next utterance
                startListening()
            } catch is AgentEndCallError {
                logger.info("[AGENT] End call requested — finishing TTS then hanging up")
                NotchActivityIndicator.removeProcess(id: "call-agent")
                await SpeechService.shared.finishStreaming()
                saveSession()
                // End the call via NotchCallButton (updates UI + calls self.end())
                NotchCallButton.endCall()
            } catch is CancellationError {
                logger.info("[AGENT] Cancelled")
                NotchActivityIndicator.removeProcess(id: "call-agent")
            } catch is AgentDismissError {
                logger.info("[AGENT] Dismissed")
                NotchActivityIndicator.removeProcess(id: "call-agent")
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
            SpeechService.shared.feedChunk(delta)
            NotchActivityIndicator.removeProcess(id: "call-agent")
        case let .toolStart(name, id):
            logger.info("[EVENT] toolStart: \(name) (id=\(id))")
            SpeechService.shared.flushBuffer()
            let detail = ToolIndicatorView.displayName(for: name)
            NotchActivityIndicator.addProcess(id: "call-agent", label: detail)
        case let .toolRunning(name, args):
            let detail = ToolIndicatorView.displayName(for: name, args: args)
            NotchActivityIndicator.updateDetail(id: "call-agent", text: detail)
        case .toolResult:
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
