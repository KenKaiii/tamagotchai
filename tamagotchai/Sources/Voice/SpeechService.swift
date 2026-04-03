import AVFoundation
import os

/// Text-to-speech service using AVSpeechSynthesizer.
/// Prefers Zoe Premium > Zoe Enhanced > Samantha Enhanced > system default.
/// Supports streaming: feed text chunks as they arrive, sentences are spoken as they complete.
/// Uses SSML, pitch/rate variation, and natural pauses for conversational speech.
@MainActor
final class SpeechService: NSObject, @unchecked Sendable {
    static let shared = SpeechService()

    private let logger = Logger(subsystem: "com.unstablemind.tamagotchai", category: "speech")
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?

    // MARK: - Speech Tuning

    /// Speech rate — premium voices handle their own prosody, so we use the default rate
    /// and let the voice's built-in intelligence handle pacing, pitch, and pauses naturally.
    private let speechRate: Float = AVSpeechUtteranceDefaultSpeechRate

    // MARK: - Streaming State

    /// Buffer for accumulating streamed text until a sentence boundary is found.
    private var streamBuffer = ""

    /// Whether we're in a streaming session.
    private var isStreaming = false

    /// Pending utterance count — used to know when all queued speech is done.
    private var pendingUtterances = 0

    /// Called when all queued utterances finish (after `finishStreaming`).
    private var streamCompletion: (() -> Void)?

    /// Whether the stream has ended (no more chunks coming).
    private var streamEnded = false

    override private init() {
        super.init()
        synthesizer.delegate = self
        resolveVoice()
    }

    /// Whether the synthesizer is currently speaking.
    var isSpeaking: Bool { synthesizer.isSpeaking }

    // MARK: - Streaming TTS

    /// Begins a streaming speech session. Call `feedChunk` as text arrives, then `finishStreaming`.
    func beginStreaming() {
        stop()
        streamBuffer = ""
        isStreaming = true
        streamEnded = false
        pendingUtterances = 0
        streamCompletion = nil
        logger.info("Streaming speech session started")
    }

    /// Feeds a text chunk from the stream. Sentences are spoken as they complete.
    func feedChunk(_ chunk: String) {
        guard isStreaming else { return }
        streamBuffer += chunk
        drainSentences()
    }

    /// Forces any buffered text to be spoken immediately (e.g. before a tool call pause).
    func flushBuffer() {
        guard isStreaming else { return }
        let text = stripMarkdown(streamBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        streamBuffer = ""

        if !text.isEmpty {
            enqueueSentences(from: text)
        }
    }

    /// Signals that the stream is complete. Speaks any remaining buffered text.
    /// Awaits until all queued utterances finish speaking.
    func finishStreaming() async {
        guard isStreaming else { return }
        streamEnded = true

        let remaining = stripMarkdown(streamBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        streamBuffer = ""

        if !remaining.isEmpty {
            enqueueSentences(from: remaining)
        }

        if pendingUtterances == 0 {
            logger.info("Streaming finished — nothing to speak")
            completeStream()
            return
        }

        // swiftformat:disable:next redundantSelf
        logger.info("Streaming finished — waiting for \(self.pendingUtterances) utterances")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            streamCompletion = {
                cont.resume()
            }
        }
    }

    /// Stops any ongoing speech immediately.
    func stop() {
        let wasSpeaking = synthesizer.isSpeaking || isStreaming
        isStreaming = false
        streamEnded = false
        streamBuffer = ""
        pendingUtterances = 0

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        if wasSpeaking {
            let cb = streamCompletion
            streamCompletion = nil
            cb?()
        }
    }

    // MARK: - Sentence Extraction

    /// Sentence-ending punctuation followed by whitespace.
    // swiftlint:disable:next force_try
    private static let sentencePattern = try! NSRegularExpression(
        pattern: "(?<=[.!?])\\s+",
        options: []
    )

    /// Extracts complete sentences from the buffer and enqueues them for speech.
    private func drainSentences() {
        let cleaned = stripMarkdown(streamBuffer)

        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let matches = Self.sentencePattern.matches(in: cleaned, options: [], range: range)

        guard let lastMatch = matches.last else { return }

        let splitIndex = cleaned.index(
            cleaned.startIndex,
            offsetBy: lastMatch.range.location + lastMatch.range.length
        )
        let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(cleaned[splitIndex...])

        streamBuffer = remainder

        if !toSpeak.isEmpty {
            enqueueSentences(from: toSpeak)
        }
    }

    // MARK: - Intelligent Utterance Creation

    /// Splits text into individual sentences and enqueues each with tailored prosody.
    private func enqueueSentences(from text: String) {
        let sentences = splitIntoSentences(text)
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            enqueueUtterance(trimmed)
        }
    }

    /// Splits a block of text into individual sentences.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex...,
            options: .bySentences
        ) { substring, _, _, _ in
            if let s = substring {
                sentences.append(s)
            }
        }
        // Fallback: if enumeration returned nothing, treat entire text as one sentence
        if sentences.isEmpty, !text.isEmpty {
            sentences.append(text)
        }
        return sentences
    }

    /// Creates and enqueues a single utterance. Premium voices handle their own prosody —
    /// pitch variation, comma pauses, question intonation — so we just set rate and let it go.
    private func enqueueUtterance(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = speechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        pendingUtterances += 1
        logger.info("Enqueuing: \(text.prefix(60))…")
        synthesizer.speak(utterance)
    }

    private func completeStream() {
        isStreaming = false
        streamEnded = false
        let cb = streamCompletion
        streamCompletion = nil
        cb?()
    }

    // MARK: - Voice Resolution

    /// Picks the best available en-US voice in priority order.
    private func resolveVoice() {
        let enUS = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }

        let preferences: [(name: String, quality: AVSpeechSynthesisVoiceQuality)] = [
            ("Zoe", .premium),
            ("Zoe", .enhanced),
            ("Samantha", .premium),
            ("Samantha", .enhanced),
            ("Ava", .premium),
            ("Ava", .enhanced),
        ]

        for pref in preferences {
            if let match = enUS.first(where: { $0.name.contains(pref.name) && $0.quality == pref.quality }) {
                voice = match
                logger.info("Selected voice: \(match.name) (\(String(describing: match.quality)))")
                return
            }
        }

        if let enhanced = enUS.first(where: { $0.quality == .enhanced }) {
            voice = enhanced
            logger.info("Fallback voice: \(enhanced.name)")
            return
        }

        voice = AVSpeechSynthesisVoice(language: "en-US")
        logger.info("Using default en-US voice")
    }

    // MARK: - Text Cleaning

    /// Strips markdown, emojis, and other non-speech content.
    private func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove code blocks
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "",
            options: .regularExpression
        )

        // Remove inline code
        result = result.replacingOccurrences(
            of: "`[^`]+`",
            with: "",
            options: .regularExpression
        )

        // Remove headers
        result = result.replacingOccurrences(
            of: "(?m)^#{1,6}\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove bold/italic markers
        result = result.replacingOccurrences(
            of: "[*_]{1,3}",
            with: "",
            options: .regularExpression
        )

        // Remove bullet points
        result = result.replacingOccurrences(
            of: "(?m)^\\s*[-*+]\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove links — keep link text
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // Remove emojis
        result = result.unicodeScalars.filter { scalar in
            !(
                (0x1F600 ... 0x1F64F).contains(scalar.value) ||
                    (0x1F300 ... 0x1F5FF).contains(scalar.value) ||
                    (0x1F680 ... 0x1F6FF).contains(scalar.value) ||
                    (0x1F700 ... 0x1F77F).contains(scalar.value) ||
                    (0x1F780 ... 0x1F7FF).contains(scalar.value) ||
                    (0x1F800 ... 0x1F8FF).contains(scalar.value) ||
                    (0x1F900 ... 0x1F9FF).contains(scalar.value) ||
                    (0x1FA00 ... 0x1FA6F).contains(scalar.value) ||
                    (0x1FA70 ... 0x1FAFF).contains(scalar.value) ||
                    (0x2600 ... 0x26FF).contains(scalar.value) ||
                    (0x2700 ... 0x27BF).contains(scalar.value) ||
                    (0xFE00 ... 0xFE0F).contains(scalar.value) ||
                    (0x200D ... 0x200D).contains(scalar.value) ||
                    (0xE0020 ... 0xE007F).contains(scalar.value)
            )
        }.reduce(into: "") { $0 += String($1) }

        // Collapse multiple newlines
        result = result.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingUtterances = max(0, pendingUtterances - 1)

            if pendingUtterances == 0, streamEnded {
                completeStream()
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingUtterances = max(0, pendingUtterances - 1)
        }
    }
}
