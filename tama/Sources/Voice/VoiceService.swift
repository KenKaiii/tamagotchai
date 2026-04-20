import AVFoundation
import os
import Speech

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "voice"
)

// MARK: - Authorization Status Helpers

extension AVAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: "not determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}

extension SFSpeechRecognizerAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}

/// Lightweight speech capture service for hold-to-talk.
/// No wake word detection — just captures speech and returns the transcript.
final class VoiceService: @unchecked Sendable {
    @MainActor static let shared = VoiceService()

    enum State: Sendable {
        case idle
        /// Engine + VP running, tap installed, but no recognition task attached
        /// yet. Used to warm up Apple's Voice Processing IO so the AEC has time
        /// to adapt before the user starts speaking. Without this warm-up the
        /// first ~1s of user audio after a TTS greeting gets aggressively gated
        /// by cold VP, making the mic feel unresponsive.
        case prewarming
        case followUp // Capturing speech (hold-to-talk or follow-up)
    }

    private(set) var state: State = .idle

    /// Called when speech capture completes with transcribed text.
    var onCaptureComplete: ((String) -> Void)?

    /// Called with audio level updates (0.0–1.0).
    var onAudioLevelChanged: ((Double) -> Void)?

    /// Called with live partial transcript as the user speaks.
    var onPartialTranscript: ((String) -> Void)?

    /// Called when speech capture fails to start (e.g., microphone error).
    var onError: ((String) -> Void)?

    /// Called once per capture session the first time the mic's RMS crosses the
    /// speech threshold — i.e. the user started speaking. Consumed by
    /// `CallMetrics` to time silence detection latency.
    var onFirstSpeech: (() -> Void)?

    // MARK: - Audio & Speech

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation: Int = 0
    private var capturedTranscript = ""

    // MARK: - Voice activity detection

    private let minSpeechRMS: Double = 5e-4
    private let speechBoostFactor: Double = 3.0
    private var noiseFloorRMS: Double = 1e-4

    /// Whether this capture session muted system audio (so we know to unmute on halt).
    private var didMuteThisSession = false

    /// Default silence duration to auto-finalize after the user stops speaking.
    /// Both audio RMS and transcription updates must be idle for this long.
    private let defaultSilenceWindow: TimeInterval = 1.0

    /// Active silence window for the current capture session (may be overridden).
    private var silenceWindow: TimeInterval = 1.0

    /// Whether the user has spoken at all during this capture.
    private var hasSpoken = false

    /// Whether the RMS has crossed the speech threshold in this capture (for telemetry).
    private var firstSpeechFired = false

    /// Last time speech was detected (RMS above threshold).
    private var lastHeard: Date?

    /// Last time the speech recognizer produced a new or updated transcript.
    private var lastTranscriptUpdate: Date?

    /// Timer that polls for silence to auto-finalize.
    private var silenceTimer: Timer?

    /// VP mode the engine was prewarmed with, so `startFollowUpCapture` can
    /// verify compatibility before reusing it.
    private var prewarmedVoiceProcessing: Bool = false

    private init() {}

    // MARK: - Public

    /// Starts capturing speech for hold-to-talk or follow-up prompts.
    /// - Parameters:
    ///   - muteAudio: When `true` (default), mutes system audio output to prevent
    ///     TTS/music from being picked up by the mic. Pass `false` when using voice processing.
    ///   - voiceProcessing: When `true`, enables Apple's Voice Processing IO on the audio
    ///     engine input node, providing hardware echo cancellation (AEC). This allows the mic
    ///     to filter out audio playing through the speakers (e.g. TTS) so only the user's
    ///     voice is captured. Use this during voice calls instead of muting system audio.
    ///   - silenceDuration: Override the silence window (seconds) before auto-finalizing.
    ///     Lower values = faster turn-taking (good for calls). `nil` uses the default (1.0s).
    func startFollowUpCapture(
        muteAudio: Bool = true,
        voiceProcessing: Bool = false,
        silenceDuration: TimeInterval? = nil
    ) {
        // Check permissions before starting to avoid audio engine errors
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            logger.warning("Cannot start speech capture — microphone permission: \(micStatus.description)")
            let msg = "Microphone permission not granted. Check System Settings > Privacy & Security > Microphone."
            onError?(msg)
            return
        }
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else {
            logger.warning("Cannot start speech capture — speech permission: \(speechStatus.description)")
            let msg = "Speech recognition permission not granted. Check System Settings > Privacy & Security."
            onError?(msg)
            return
        }

        logger.info("Starting speech capture")

        // If we were prewarmed with matching VP settings, reuse the engine so
        // Apple's Voice Processing IO keeps its already-adapted AEC state.
        // Tearing it down and rebuilding would force another ~1s cold start.
        let canReusePrewarm = state == .prewarming && prewarmedVoiceProcessing == voiceProcessing && audioEngine != nil
        if !canReusePrewarm {
            generation += 1
            haltPipeline()
        }

        silenceWindow = silenceDuration ?? defaultSilenceWindow
        state = .followUp
        capturedTranscript = ""
        hasSpoken = false
        firstSpeechFired = false
        lastHeard = Date()
        lastTranscriptUpdate = nil

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.defaultTaskHint = .dictation
        speechRecognizer = recognizer

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("Speech recognizer not available")
            if !canReusePrewarm { state = .idle } else { haltPipeline()
                state = .idle
            }
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        request.addsPunctuation = false
        recognitionRequest = request

        // Mute system audio so music/sounds don't get picked up by the mic
        if muteAudio {
            SystemAudioMuter.muteSystemOutput()
            didMuteThisSession = true
        } else {
            didMuteThisSession = false
        }

        if !canReusePrewarm {
            guard setupCaptureEngine(voiceProcessing: voiceProcessing) else {
                state = .idle
                return
            }
        } else {
            logger.info("Reusing prewarmed capture engine (VP already adapted)")
        }

        let currentGeneration = generation

        recognitionTask = speechRecognizer.recognitionTask(
            with: request
        ) { [weak self] result, _ in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let sself = self
            DispatchQueue.main.async { [weak sself] in
                guard let sself, sself.generation == currentGeneration else { return }
                guard sself.state == .followUp else { return }

                if let transcript, !transcript.isEmpty {
                    let changed = transcript != sself.capturedTranscript
                    sself.capturedTranscript = transcript
                    sself.hasSpoken = true
                    if changed {
                        sself.lastTranscriptUpdate = Date()
                    }
                    sself.onPartialTranscript?(transcript)
                }

                if isFinal {
                    sself.finalize()
                }
            }
        }

        // Start silence monitor — auto-finalizes when user stops speaking
        startSilenceMonitor()

        logger.info("Speech capture started (generation: \(currentGeneration))")
    }

    /// Starts the audio engine with Voice Processing enabled but without
    /// attaching a speech recognizer. Lets Apple's AEC adapt to the current
    /// room/speaker acoustics so that when `startFollowUpCapture` is called
    /// shortly after, the first user audio isn't gated by a cold VP filter.
    ///
    /// Idempotent: calling while already prewarmed with the same VP mode is a
    /// no-op. If the service is already capturing (`.followUp`), does nothing.
    ///
    /// Does NOT mute system audio — the caller is expected to be playing
    /// something (e.g. a greeting) through the output that VP should adapt to.
    func prewarmCapture(voiceProcessing: Bool = true) {
        guard state != .followUp else { return }
        if state == .prewarming, prewarmedVoiceProcessing == voiceProcessing, audioEngine != nil {
            return
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            logger.info("Skipping prewarm — microphone permission: \(micStatus.description)")
            return
        }

        logger.info("Prewarming capture engine (VP=\(voiceProcessing))")
        generation += 1
        haltPipeline()

        guard setupCaptureEngine(voiceProcessing: voiceProcessing) else { return }
        state = .prewarming
        prewarmedVoiceProcessing = voiceProcessing
    }

    /// Builds the AVAudioEngine with optional VP, installs the tap, and starts
    /// the engine. Shared between `prewarmCapture` and `startFollowUpCapture`.
    /// Returns `false` on failure (engine discarded, caller should bail out).
    private func setupCaptureEngine(voiceProcessing: Bool) -> Bool {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode

        // Enable Voice Processing IO for echo cancellation (AEC).
        // Must be done BEFORE reading the format — VP changes the input format.
        if voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                logger.info("Voice processing (AEC) enabled on input node")
            } catch {
                logger.error("Failed to enable voice processing: \(error.localizedDescription)")
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Input node format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            logger.error("Invalid audio format")
            audioEngine = nil
            return false
        }

        // VP may change the format to multi-channel. The speech recognizer
        // needs mono audio, so force a 1-channel format at the same sample rate.
        let recordingFormat: AVAudioFormat = if voiceProcessing, hwFormat.channelCount > 1,
                                                let mono = AVAudioFormat(
                                                    standardFormatWithSampleRate: hwFormat.sampleRate,
                                                    channels: 1
                                                )
        {
            mono
        } else {
            hwFormat
        }

        if recordingFormat !== hwFormat {
            logger.info("Using mono tap format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: recordingFormat
        ) { [weak self] buffer, _ in
            // During .prewarming the request is nil — buffers are harmlessly
            // dropped, which is fine: VP only needs the engine running to adapt.
            self?.recognitionRequest?.append(buffer)
            guard let rms = Self.calculateRMS(buffer: buffer) else { return }
            let sself = self
            DispatchQueue.main.async { [weak sself] in
                guard let sself, sself.state == .followUp else { return }
                sself.noteAudioLevel(rms: rms)
                let threshold = max(sself.minSpeechRMS, sself.noiseFloorRMS * sself.speechBoostFactor)
                sself.onAudioLevelChanged?(min(1.0, max(0.0, rms / threshold)))
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            onError?("Could not access microphone. It may be in use by another app.")
            audioEngine = nil
            return false
        }
        return true
    }

    /// Stops capture and returns to idle without invoking the callback.
    func stopFollowUpCapture() {
        guard state == .followUp || state == .prewarming else { return }
        // swiftformat:disable:next redundantSelf
        logger.info("Stopping speech capture (was \(String(describing: self.state)))")
        generation += 1
        haltPipeline()
        state = .idle
    }

    // MARK: - Private

    private func finalize() {
        guard state == .followUp else { return }
        let text = capturedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split { $0.isWhitespace }.count
        logger.info("🔇 Speech capture finalized — \(words) words, \(text.count) chars")

        haltPipeline()
        state = .idle
        capturedTranscript = ""
        hasSpoken = false
        firstSpeechFired = false
        lastTranscriptUpdate = nil

        onCaptureComplete?(text)
    }

    /// Polls for silence — auto-finalizes when both audio RMS and transcript
    /// updates have been idle for `silenceWindow`. This prevents cutting off
    /// the user during natural pauses between words or sentences.
    private func startSilenceMonitor() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, state == .followUp else {
                self?.silenceTimer?.invalidate()
                self?.silenceTimer = nil
                return
            }
            guard hasSpoken, let lastAudio = lastHeard else { return }

            let now = Date()
            let audioSilent = now.timeIntervalSince(lastAudio) >= silenceWindow

            // Also require that the recognizer hasn't produced new text recently.
            // The recognizer often updates transcript even during brief audio dips,
            // so this catches cases where RMS drops but the user is still speaking.
            let transcriptIdle: Bool = if let lastUpdate = lastTranscriptUpdate {
                now.timeIntervalSince(lastUpdate) >= silenceWindow
            } else {
                // No transcript yet — don't finalize on audio silence alone
                false
            }

            if audioSilent, transcriptIdle {
                let audioIdle = String(format: "%.2f", now.timeIntervalSince(lastAudio))
                let txIdle = String(format: "%.2f", now.timeIntervalSince(lastTranscriptUpdate ?? now))
                let window = String(format: "%.1f", silenceWindow)
                logger
                    .info(
                        "🔇 Silence trigger (window=\(window)s, audio idle \(audioIdle)s, transcript idle \(txIdle)s)"
                    )
                finalize()
            }
        }
    }

    private func haltPipeline() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        prewarmedVoiceProcessing = false

        speechRecognizer = nil

        // Restore system audio after voice capture ends (only if we muted it)
        if didMuteThisSession {
            SystemAudioMuter.unmuteSystemOutput()
            didMuteThisSession = false
        }
    }

    private func noteAudioLevel(rms: Double) {
        let alpha: Double = rms < noiseFloorRMS ? 0.08 : 0.01
        noiseFloorRMS = max(1e-7, noiseFloorRMS + (rms - noiseFloorRMS) * alpha)

        let threshold = max(minSpeechRMS, noiseFloorRMS * speechBoostFactor)
        if rms >= threshold {
            lastHeard = Date()
            if !firstSpeechFired {
                // Mic crossed the speech threshold for the first time this
                // capture. Fire the telemetry hook so CallMetrics can start
                // measuring "how long did the user speak".
                firstSpeechFired = true
                onFirstSpeech?()
            }
        }
    }

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Double? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        var sum: Float = 0
        for i in 0 ..< frameLength {
            let sample = channelDataValue[i]
            sum += sample * sample
        }
        return Double(sqrt(sum / Float(frameLength)))
    }
}
