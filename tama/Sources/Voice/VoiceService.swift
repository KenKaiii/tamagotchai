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

    /// Silence duration to auto-finalize after the user stops speaking.
    /// Both audio RMS and transcription updates must be idle for this long.
    private let silenceWindow: TimeInterval = 1.0

    /// Whether the user has spoken at all during this capture.
    private var hasSpoken = false

    /// Last time speech was detected (RMS above threshold).
    private var lastHeard: Date?

    /// Last time the speech recognizer produced a new or updated transcript.
    private var lastTranscriptUpdate: Date?

    /// Timer that polls for silence to auto-finalize.
    private var silenceTimer: Timer?

    private init() {}

    // MARK: - Public

    /// Starts capturing speech for hold-to-talk or follow-up prompts.
    func startFollowUpCapture() {
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
        generation += 1
        haltPipeline()

        state = .followUp
        capturedTranscript = ""
        hasSpoken = false
        lastHeard = Date()
        lastTranscriptUpdate = nil

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.defaultTaskHint = .dictation
        speechRecognizer = recognizer

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("Speech recognizer not available")
            state = .idle
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        request.addsPunctuation = false
        recognitionRequest = request

        // Mute system audio so music/sounds don't get picked up by the mic
        SystemAudioMuter.muteSystemOutput()

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            logger.error("Invalid audio format")
            audioEngine = nil
            state = .idle
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: recordingFormat
        ) { [weak self] buffer, _ in
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

        let currentGeneration = generation

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            onError?("Could not access microphone. It may be in use by another app.")
            audioEngine = nil
            state = .idle
            return
        }

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

    /// Stops capture and returns to idle without invoking the callback.
    func stopFollowUpCapture() {
        guard state == .followUp else { return }
        logger.info("Stopping speech capture")
        generation += 1
        haltPipeline()
        state = .idle
    }

    // MARK: - Private

    private func finalize() {
        guard state == .followUp else { return }
        let text = capturedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Speech capture finalized — text length: \(text.count)")

        haltPipeline()
        state = .idle
        capturedTranscript = ""
        hasSpoken = false
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
                let audioIdle = String(format: "%.1f", now.timeIntervalSince(lastAudio))
                let txIdle = String(format: "%.1f", now.timeIntervalSince(lastTranscriptUpdate ?? now))
                logger.info("Silence detected — audio idle \(audioIdle)s, transcript idle \(txIdle)s")
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

        speechRecognizer = nil

        // Restore system audio after voice capture ends
        SystemAudioMuter.unmuteSystemOutput()
    }

    private func noteAudioLevel(rms: Double) {
        let alpha: Double = rms < noiseFloorRMS ? 0.08 : 0.01
        noiseFloorRMS = max(1e-7, noiseFloorRMS + (rms - noiseFloorRMS) * alpha)

        let threshold = max(minSpeechRMS, noiseFloorRMS * speechBoostFactor)
        if rms >= threshold {
            lastHeard = Date()
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
