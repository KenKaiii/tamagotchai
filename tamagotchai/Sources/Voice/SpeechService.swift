import AVFoundation
import KokoroSwift
import os

/// Text-to-speech service using Kokoro TTS.
/// Supports streaming: feed text chunks as they arrive, sentences are spoken as they complete.
/// Audio generation runs off the main thread to avoid blocking the UI.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let logger = Logger(subsystem: "com.unstablemind.tamagotchai", category: "speech")

    // MARK: - Persistent Audio Engine

    /// Single persistent audio engine — reused across all playback sessions.
    /// Recreating AVAudioEngine per play causes zombie engine instances that
    /// fight for audio resources and cause stuttering on subsequent plays.
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineStarted = false

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

    /// Queue of audio buffers waiting to be played sequentially.
    private var bufferQueue: [AVAudioPCMBuffer] = []

    /// Whether the player is currently playing a buffer.
    private var isPlaying = false

    /// Active generation task (so we can cancel on stop).
    private var generationTask: Task<Void, Never>?

    /// Serial queue for Kokoro TTS generation. KokoroTTS uses NLTagger internally
    /// (via MisakiSwift G2P) which is not thread-safe and crashes with EXC_BAD_ACCESS
    /// if called concurrently from multiple threads.
    private let generationQueue = DispatchQueue(
        label: "com.unstablemind.tamagotchai.tts-generation",
        qos: .userInitiated
    )

    // MARK: - Constants

    /// Max characters per chunk for Kokoro TTS. Kokoro's token limit is 510,
    /// and ~200 chars provides a safe margin accounting for phonemization variance.
    private static let maxChunkChars = 200

    /// Minimum fragment length — shorter pieces are merged to avoid choppy playback.
    private static let minFragmentLength = 20

    private init() {
        audioEngine.attach(playerNode)
    }

    /// Whether the service is currently speaking.
    var isSpeaking: Bool { isPlaying || !bufferQueue.isEmpty || pendingUtterances > 0 }

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
        let wasSpeaking = isStreaming || isPlaying
        isStreaming = false
        streamEnded = false
        streamBuffer = ""
        pendingUtterances = 0

        generationTask?.cancel()
        generationTask = nil

        stopPlayback()

        if wasSpeaking {
            let cb = streamCompletion
            streamCompletion = nil
            cb?()
        }
    }

    private func stopPlayback() {
        bufferQueue.removeAll()
        isPlaying = false
        playerNode.stop()
    }

    // MARK: - Audio Engine Management

    private func ensureEngineRunning(format: AVAudioFormat) {
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                engineStarted = true
                logger.debug("Audio engine started")
            } catch {
                logger.error("Audio engine failed to start: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sentence Extraction

    // Sentence-ending punctuation followed by whitespace.
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

    // MARK: - Utterance Creation

    /// Splits text into speakable chunks, merges short fragments, and enqueues each.
    private func enqueueSentences(from text: String) {
        let sentences = splitIntoSentences(text)
        let chunks = splitLongSentences(sentences)
        let merged = mergeShortFragments(chunks)

        for chunk in merged {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if sentences.isEmpty, !text.isEmpty {
            sentences.append(text)
        }
        return sentences
    }

    /// Splits any sentence exceeding maxChunkChars at clause boundaries.
    private func splitLongSentences(_ sentences: [String]) -> [String] {
        var result: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= Self.maxChunkChars {
                result.append(trimmed)
            } else {
                result.append(contentsOf: splitAtClauseBoundaries(trimmed))
            }
        }
        return result
    }

    /// Splits a long sentence at comma, semicolon, or dash boundaries.
    private func splitAtClauseBoundaries(_ text: String) -> [String] {
        // swiftlint:disable:next force_try
        let pattern = try! NSRegularExpression(pattern: "[,;—–]\\s+", options: [])
        let nsText = text as NSString
        let matches = pattern.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else {
            // No clause boundaries — hard split at maxChunkChars
            return stride(from: 0, to: text.count, by: Self.maxChunkChars).map { start in
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(startIdx, offsetBy: Self.maxChunkChars, limitedBy: text.endIndex) ?? text
                    .endIndex
                return String(text[startIdx ..< endIdx])
            }
        }

        var chunks: [String] = []
        var current = ""
        var lastEnd = 0

        for match in matches {
            let boundary = match.range.location + match.range.length
            let piece = nsText.substring(with: NSRange(location: lastEnd, length: boundary - lastEnd))
            if current.count + piece.count > Self.maxChunkChars, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = piece
            } else {
                current += piece
            }
            lastEnd = boundary
        }

        // Remainder
        if lastEnd < nsText.length {
            current += nsText.substring(from: lastEnd)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    /// Merges fragments shorter than minFragmentLength with adjacent chunks.
    private func mergeShortFragments(_ chunks: [String]) -> [String] {
        guard chunks.count > 1 else { return chunks }
        var result: [String] = []
        var accumulator = ""

        for chunk in chunks {
            if accumulator.isEmpty {
                accumulator = chunk
            } else if accumulator.count < Self.minFragmentLength || chunk.count < Self.minFragmentLength {
                accumulator += " " + chunk
            } else {
                result.append(accumulator)
                accumulator = chunk
            }
        }
        if !accumulator.isEmpty {
            result.append(accumulator)
        }
        return result
    }

    /// Enqueues text for TTS generation on a background thread, then queues playback.
    private func enqueueUtterance(_ text: String) {
        pendingUtterances += 1
        logger.info("Enqueuing: \(text.prefix(60))…")

        let manager = KokoroManager.shared
        guard manager.isReady else {
            logger.warning("Kokoro not ready, skipping: \(text.prefix(40))…")
            utteranceDidFinish()
            return
        }

        // Capture engine state on MainActor, then generate off main thread
        guard let snapshot = manager.captureGenerationContext() else {
            logger.warning("No voice/engine available, skipping: \(text.prefix(40))…")
            utteranceDidFinish()
            return
        }

        generationTask = Task {
            let result: AVAudioPCMBuffer? = await withCheckedContinuation { continuation in
                self.generationQueue.async {
                    let buffer = KokoroManager.generateAudioBufferOffMain(text: text, context: snapshot)
                    continuation.resume(returning: buffer)
                }
            }

            guard !Task.isCancelled else { return }

            if let result {
                bufferQueue.append(result)
                playNextBuffer()
            } else {
                logger.warning("Kokoro generation failed, skipping: \(text.prefix(40))…")
                utteranceDidFinish()
            }
        }
    }

    /// Decrements pending count and checks for stream completion.
    private func utteranceDidFinish() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if pendingUtterances == 0, streamEnded {
            completeStream()
        }
    }

    /// Plays the next buffer in the queue if nothing is currently playing.
    private func playNextBuffer() {
        guard !isPlaying, !bufferQueue.isEmpty else { return }
        isPlaying = true

        let buffer = bufferQueue.removeFirst()
        ensureEngineRunning(format: buffer.format)

        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.utteranceDidFinish()

                if !self.bufferQueue.isEmpty {
                    self.playNextBuffer()
                }
            }
        }
        playerNode.play()
    }

    private func completeStream() {
        isStreaming = false
        streamEnded = false
        let cb = streamCompletion
        streamCompletion = nil
        cb?()
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
