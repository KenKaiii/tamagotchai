import AVFoundation
import os

/// Text-to-speech service using Kokoro TTS.
/// Supports streaming: feed text chunks as they arrive, sentences are spoken as they complete.
/// Audio generation runs off the main thread to avoid blocking the UI.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let logger = Logger(subsystem: "com.unstablemind.tama", category: "speech")

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

    /// A PCM buffer paired with its per-word timings from Kokoro. Carried
    /// through the ordered-slot and playback queues so the word-level visual
    /// scheduler (`firePendingVisualsForUpcoming`) has the exact offset at
    /// which each word is spoken.
    private struct PlaybackItem {
        let buffer: AVAudioPCMBuffer
        let wordTimings: [WordTiming]
    }

    /// Queue of audio buffers waiting to be played sequentially.
    private var bufferQueue: [PlaybackItem] = []

    /// Whether the player is currently playing a buffer.
    private var isPlaying = false

    /// Active generation tasks (so we can cancel on stop).
    private var generationTasks: [Task<Void, Never>] = []

    /// Ordered slots for audio buffers — ensures playback order matches enqueue order
    /// even when concurrent TTS requests complete out of order.
    private var orderedSlots: [Int: PlaybackItem] = [:]
    private var nextSlotIndex = 0
    private var nextPlaySlot = 0

    // MARK: - Spoken-Chars Barrier (voice ↔ visual sync)

    /// Cumulative count of input characters fed into `feedChunk` since the
    /// current streaming session began. Drives the voice/visual sync barrier
    /// together with `inputCharsSpoken` below.
    private var inputCharsFed = 0

    /// Cumulative count of input characters whose audio has actually finished
    /// playing through `AVAudioPlayerNode`. Monotonically increasing within a
    /// streaming session; advanced each time a scheduled buffer reports
    /// completion. Visual tools (point, highlight, etc.) wait on this to stay
    /// synchronized with the agent's narration — see `awaitSpokenChars`.
    private var inputCharsSpoken = 0

    /// Watermark per slot — the value of `inputCharsFed` captured at the
    /// moment the utterance was enqueued. When the slot's buffer finishes
    /// playing, `inputCharsSpoken` is advanced to this watermark.
    private var slotWatermarks: [Int: Int] = [:]

    /// Watermark of the buffer currently being played (popped from
    /// `bufferQueue`). Used to advance `inputCharsSpoken` on completion.
    private var playingBufferWatermark: Int = 0

    /// Watermarks parallel to `bufferQueue` — `bufferQueue[i]` is played with
    /// watermark `bufferQueueWatermarks[i]`.
    private var bufferQueueWatermarks: [Int] = []

    /// Suspended callers waiting for `inputCharsSpoken` to reach their target.
    /// Resumed whenever a buffer completes and advances the counter past their
    /// target, or when the stream stops (to avoid deadlocking tool execution).
    private var barrierWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Word-level visual sync: callers register a visual action keyed by a
    /// SHORT LABEL (e.g. "Apple", "Wi-Fi", "Finder"). When the TTS stream
    /// enqueues a buffer whose Kokoro word timings include that label, the
    /// action is scheduled via `DispatchQueue.main.asyncAfter` to fire at
    /// the EXACT moment that word begins being uttered. Matches the pattern
    /// used by Web Speech API (`onboundary.charIndex`) and OpenAI Realtime
    /// (`response.audio_transcript.delta` + interleaved function calls).
    ///
    /// Unlike `barrierWaiters` (which suspend an async task), these are
    /// fire-and-forget — the agent loop registers and returns tool_result
    /// instantly so the model can keep streaming the narration that drives
    /// the firing.
    private struct PendingVisual {
        let id: String
        /// All significant (non-stopword) tokens from the visual's label,
        /// lowercased and stripped of punctuation. For label "the File
        /// menu" this is ["file", "menu"]; for "Wi-Fi" it's ["wi", "fi"].
        /// The FIRST entry is the primary match anchor; subsequent entries
        /// are tried as fallbacks if the primary doesn't appear in
        /// narration. Empty only when the label is purely stopwords,
        /// which we refuse at registration time.
        let tokens: [String]
        /// Full lowercased label preserved for substring fallbacks and
        /// for logging. Punctuation preserved so "wi-fi" still matches a
        /// Kokoro-tokenised "wi-fi" unit via `contains`.
        let fullLabel: String
        let action: @MainActor () -> Void
        let registeredAt: Date
    }

    /// Common English stopwords skipped when picking a visual's primary
    /// match token. Without this, a label like "the Apple menu" would
    /// anchor on "the" and fire the cursor on the FIRST "the" uttered in
    /// narration — usually the wrong moment entirely. The list is narrow
    /// on purpose: only true semantic-free words that never name a UI
    /// target. Kept as a private static set so the allocator hits it once.
    private static let matchStopwords: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "it", "its",
        "your", "my", "our", "their", "his", "her",
        "is", "was", "are", "were", "be", "been", "being",
        "and", "or", "but", "of", "to", "for", "in", "on", "at", "by",
        "with", "from",
    ]

    private var pendingVisuals: [PendingVisual] = []

    /// Current cumulative spoken chars — exposed for callers that need to
    /// compute spacing relative to the latest playback position.
    var spokenCharsSnapshot: Int { inputCharsSpoken }

    /// Timer that auto-flushes buffered text when no new chunks arrive for `flushDelay`.
    /// Tokens arrive every ~20-50ms, so the timer only fires during genuine pauses
    /// (between sentences, before tool calls, or at end of response).
    private var flushTimer: Timer?

    /// Whether we've already sent the first utterance to TTS in this streaming session.
    /// The first utterance is dispatched eagerly (at a clause boundary or `eagerFlushChars`)
    /// so that Kokoro can start generating audio while more text streams in.
    private var hasFlushedFirst = false

    // MARK: - Telemetry Callbacks

    /// Fires the first time a TTS chunk is handed to Kokoro in a streaming session.
    var onFirstChunkEnqueued: (@MainActor () -> Void)?
    /// Fires the first time a generated audio buffer lands in the play queue.
    var onFirstAudioReady: (@MainActor () -> Void)?
    /// Fires the first time the audio engine starts playing a buffer this session.
    var onFirstAudioPlayback: (@MainActor () -> Void)?
    /// Fires when a playback gap is detected (queue empty while stream still active).
    /// Argument is the gap duration in seconds.
    var onPlaybackGap: (@MainActor (TimeInterval) -> Void)?

    // Internal flags + timestamps driving the telemetry callbacks above.
    private var firstChunkEnqueuedFired = false
    private var firstAudioReadyFired = false
    private var firstAudioPlaybackFired = false
    /// Time the audio engine finished playing the last buffer, if the queue
    /// was empty and more utterances were still pending (we're waiting for
    /// Kokoro). Compared against the next playNextBuffer() call to compute
    /// mid-stream dead-air gaps.
    private var playbackUnderrunAt: Date?

    /// Serial queue for Kokoro TTS generation. KokoroTTS uses NLTagger internally
    /// (via MisakiSwift G2P) which is not thread-safe and crashes with EXC_BAD_ACCESS
    /// if called concurrently from multiple threads.
    private let generationQueue = DispatchQueue(
        label: "com.unstablemind.tama.tts-generation",
        qos: .userInitiated
    )

    // MARK: - Constants

    /// Max characters per chunk for Kokoro TTS. Kokoro's token limit is 510,
    /// and ~200 chars provides a safe margin accounting for phonemization variance.
    private static let maxChunkChars = 200

    /// Minimum fragment length — shorter pieces are merged to avoid choppy playback.
    private static let minFragmentLength = 20

    /// Minimum character count before the first eager flush.
    /// Lower = faster time-to-first-audio, higher = more natural speech.
    private static let eagerFlushChars = 30

    /// After the first flush, if the buffer grows past this many characters
    /// and contains a clause boundary (comma, semicolon, dash), we drain up to
    /// that boundary instead of waiting for a sentence-ending punctuation.
    /// Keeps Kokoro continuously fed during long sentences so playback never
    /// outruns generation (dead-air prevention).
    private static let clauseFlushChars = 60

    /// How long to wait after the last chunk before auto-flushing the buffer.
    /// Tokens arrive every ~20-50ms so the timer only fires during genuine
    /// pauses. Tight value keeps end-of-turn lag minimal while still allowing
    /// the LLM to naturally pause mid-sentence without truncation.
    private static let flushDelay: TimeInterval = 0.3

    private init() {
        audioEngine.attach(playerNode)
    }

    /// Whether the service is currently speaking.
    var isSpeaking: Bool { isPlaying || !bufferQueue.isEmpty || pendingUtterances > 0 }

    /// True while a streaming session is active (between `beginStreaming()`
    /// and `finishStreaming()`/`stop()`). Unlike `isSpeaking`, this stays
    /// true across the gap between the model finishing its narration and
    /// the next turn's audio starting — so callers that need "am I in a
    /// voice call right now?" (like `AgentLoop`'s visual-tool gating) can
    /// trust it between turns. `isSpeaking` answers the narrower "is audio
    /// physically playing this instant?" question and flips to false in
    /// those quiet inter-turn gaps.
    var isVoiceSessionActive: Bool { isStreaming }

    // MARK: - Streaming TTS

    /// Begins a streaming speech session. Call `feedChunk` as text arrives, then `finishStreaming`.
    func beginStreaming() {
        stop()
        streamBuffer = ""
        isStreaming = true
        streamEnded = false
        pendingUtterances = 0
        streamCompletion = nil
        hasFlushedFirst = false
        flushTimer?.invalidate()
        flushTimer = nil
        nextSlotIndex = 0
        nextPlaySlot = 0
        orderedSlots.removeAll()
        inputCharsFed = 0
        inputCharsSpoken = 0
        slotWatermarks.removeAll()
        playingBufferWatermark = 0
        bufferQueueWatermarks.removeAll()
        pendingVisuals.removeAll()
        firstChunkEnqueuedFired = false
        firstAudioReadyFired = false
        firstAudioPlaybackFired = false
        playbackUnderrunAt = nil
        prewarmEngine()
        logger.info("Streaming speech session started")
    }

    /// Feeds a text chunk from the stream. Sentences are spoken as they complete.
    ///
    /// Strategy:
    /// 1. **First flush** — eagerly sent at the first clause/sentence boundary after
    ///    `eagerFlushChars` so Kokoro starts generating audio immediately.
    /// 2. **Subsequent flushes** — drained at sentence boundaries for natural pacing.
    /// 3. **Idle timer** — catches any remaining text after a short pause (e.g. the
    ///    last partial sentence before a tool call or end of response).
    func feedChunk(_ chunk: String) {
        guard isStreaming else { return }
        // Count raw input chars BEFORE any stripping/drainage so the barrier
        // aligns 1:1 with the agent loop's own cumulative textDelta count.
        inputCharsFed += chunk.count
        streamBuffer += chunk

        if !hasFlushedFirst {
            tryEagerFlush()
        } else {
            drainSentences()
        }

        scheduleFlush()
    }

    // MARK: - Spoken-Chars Barrier

    /// Suspends the caller until `target` input characters have finished
    /// playing through the audio engine, or the stream ends. Used by visual
    /// tools (point, highlight, arrow, emphasize, countdown, scroll_hint,
    /// show_shortcut) to fire at the exact moment their narration reaches
    /// the user's ears instead of racing ahead.
    ///
    /// Returns immediately when:
    /// - `target` has already been spoken (counter caught up / past it), or
    /// - no streaming session is active (panel mode with no TTS), or
    /// - the stream is stopped while waiting (caller resumes, tool proceeds).
    func awaitSpokenChars(_ target: Int) async {
        if target <= inputCharsSpoken {
            let spokenNow = inputCharsSpoken
            logger.info("barrier: target \(target) already spoken (=\(spokenNow)) — returning immediately")
            return
        }
        if !isStreaming {
            logger.info("barrier: target \(target) but not streaming — returning immediately")
            return
        }
        // Force-drain any residual text in the stream buffer. Without this,
        // short tail fragments (<20 chars) arriving between a toolStart and
        // the stream's end are held back by `flushBuffer`'s fragment-skip
        // guard — they count toward `inputCharsFed` but never get enqueued,
        // so `inputCharsSpoken` can never reach `target` and the barrier
        // would hang forever. See the 169/153 stall investigated in logs.
        forceDrainBuffer()
        if target <= inputCharsSpoken { return }
        let fedNow = inputCharsFed
        let spokenNow = inputCharsSpoken
        let queuedNow = bufferQueue.count
        let playingNow = isPlaying
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            barrierWaiters.append((target: target, continuation: cont))
            logger
                .info(
                    "barrier: suspending for \(target) chars (fed=\(fedNow), spoken=\(spokenNow), queued=\(queuedNow), playing=\(playingNow))"
                )
        }
    }

    /// Forcibly enqueues whatever is in `streamBuffer`, bypassing the
    /// `minFragmentLength` guard that `flushBuffer` applies for smoothness.
    /// Used by the barrier path where short trailing fragments MUST reach the
    /// TTS queue so their chars are eventually counted as spoken.
    private func forceDrainBuffer() {
        guard isStreaming else { return }
        let text = stripMarkdown(streamBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        logger.info("forceDrainBuffer — text: \(text.prefix(80), privacy: .public)")
        streamBuffer = ""
        enqueueSentences(from: text)
    }

    /// Advances `inputCharsSpoken` to at least `watermark` and resumes every
    /// barrier waiter whose target is now satisfied. Called from the audio
    /// engine's buffer-completion callback (main actor).
    private func advanceSpokenChars(to watermark: Int) {
        guard watermark > inputCharsSpoken else { return }
        let previous = inputCharsSpoken
        inputCharsSpoken = watermark
        let waiterCount = barrierWaiters.count
        logger.info("barrier: advanced spoken \(previous) → \(watermark) (waiters=\(waiterCount))")
        resumeReadyWaiters()
    }

    // MARK: - Word-Level Visual Scheduling

    /// Register a visual action to fire the instant TTS utters `label`.
    /// Matching is case-insensitive and checks the FIRST word of `label`
    /// against Kokoro's per-word tokens. If the label is already in an
    /// already-enqueued buffer, the action is scheduled at the buffer's
    /// matching-word offset. If no match is found in any currently-known
    /// buffer, the visual stays pending — every subsequently enqueued
    /// buffer is scanned, and any lingering pending visuals are
    /// force-fired on stream completion as a safety net.
    func registerPendingVisual(id: String, label: String, action: @escaping @MainActor () -> Void) {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            logger.info("visual: \(id) has empty label — firing immediately")
            action()
            return
        }
        // Tokenise the label into significant words. Punctuation and
        // whitespace are the split boundaries, then stopwords are dropped.
        // The first survivor is the primary match anchor; the rest are
        // fallbacks for when the narration paraphrases and the primary
        // word never shows up (e.g. primary "control" missed, but the
        // narration mentions the fallback "center" from "Control Center").
        let allTokens = normalized
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { !$0.isEmpty }
        let significant = allTokens.filter { !Self.matchStopwords.contains($0) }
        // If stopword filtering left nothing, fall back to raw tokens so
        // we at least have SOMETHING to match on — better a noisy match
        // than no match at all.
        let tokens = significant.isEmpty ? allTokens : significant
        guard !tokens.isEmpty else {
            logger.info("visual: \(id) label '\(normalized)' has no tokens — firing immediately")
            action()
            return
        }
        let visual = PendingVisual(
            id: id,
            tokens: tokens,
            fullLabel: normalized,
            action: action,
            registeredAt: Date()
        )
        pendingVisuals.append(visual)
        logger.info("visual: \(id) registered for tokens \(tokens) (full: '\(normalized)')")
    }

    /// When a playback item is about to start, scan the buffer's word
    /// timings against every currently-pending visual and fire matches
    /// via `DispatchQueue.main.asyncAfter` at the word's exact offset.
    /// This is the heart of word-level sync: by combining the buffer's
    /// wall-clock start time with Kokoro's per-word duration prediction,
    /// we fire cursors with ~10ms accuracy regardless of where the model
    /// placed the tool_use block in its output stream.
    private func schedulePendingVisualsForItem(_ item: PlaybackItem, bufferStartTime: CFTimeInterval) {
        guard !pendingVisuals.isEmpty, !item.wordTimings.isEmpty else { return }

        var remaining: [PendingVisual] = []
        for visual in pendingVisuals {
            guard let match = findMatch(for: visual, in: item.wordTimings) else {
                remaining.append(visual)
                continue
            }
            let now = CACurrentMediaTime()
            let fireAt = bufferStartTime + match.startSec
            let delay = max(0, fireAt - now)
            let visualId = visual.id
            let matchedWord = match.text
            let action = visual.action
            logger
                .info(
                    "visual: \(visualId) matched word '\(matchedWord)' at +\(String(format: "%.2f", match.startSec))s — firing in \(String(format: "%.3f", delay))s"
                )
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }
        pendingVisuals = remaining
    }

    /// Find the first word in `timings` that matches this visual's label.
    /// Walks the buffer's word tokens in playback order and, for each one,
    /// checks against the visual's significant tokens. The primary token
    /// is tried first; if nothing hits, subsequent significant tokens are
    /// used as fallbacks. A final pass uses substring containment on the
    /// full label for cases where Kokoro emits a multi-word unit like
    /// "wi-fi" as a single token.
    ///
    /// Matching preserves narration order — we return the FIRST word in
    /// this buffer that matches ANY of the visual's tokens, so two
    /// visuals registered with overlapping tokens (rare) still fire in
    /// the order their words are spoken.
    private func findMatch(for visual: PendingVisual, in timings: [WordTiming]) -> WordTiming? {
        for timing in timings {
            let word = timing.text.lowercased()
            // Try every significant token in the visual's label. Equality
            // wins over prefix, but we accept either for flexibility
            // ("apple" matches "apples"; "wifi" matches "wi" via prefix).
            for token in visual.tokens {
                if word == token { return timing }
                if word.hasPrefix(token), token.count >= 3 { return timing }
                if token.hasPrefix(word), word.count >= 3 { return timing }
            }
            // Substring check on full label as last resort — catches
            // Kokoro-tokenised multi-word units like "wi-fi".
            if visual.fullLabel.contains(word), word.count >= 3 { return timing }
        }
        return nil
    }

    /// Fires any remaining pending visuals immediately. Called on stream
    /// completion as a safety net — if the model emitted a tool_use whose
    /// label never appeared in subsequent narration, we still want the
    /// cursor to show (better late than never). Preserves registration
    /// order.
    private func fireAllPendingVisuals() {
        guard !pendingVisuals.isEmpty else { return }
        let visuals = pendingVisuals
        pendingVisuals.removeAll()
        logger.info("visual: force-firing \(visuals.count) unmatched visual(s) at stream end")
        for visual in visuals {
            visual.action()
        }
    }

    /// Resumes any waiter whose target is ≤ `inputCharsSpoken`, removing them
    /// from the pending list.
    private func resumeReadyWaiters() {
        guard !barrierWaiters.isEmpty else { return }
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in barrierWaiters {
            if waiter.target <= inputCharsSpoken {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        barrierWaiters = remaining
    }

    /// Resumes ALL pending waiters — called on `stop()` / stream completion to
    /// avoid deadlocking tools that are waiting for audio that will never play.
    private func releaseAllBarrierWaiters() {
        guard !barrierWaiters.isEmpty else { return }
        let waiters = barrierWaiters
        barrierWaiters.removeAll()
        logger.debug("barrier: releasing \(waiters.count) waiter(s) due to stop/complete")
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    /// Cancel all pending visuals without firing them. Used when the user
    /// explicitly stops the session — firing cursors after stop would be
    /// surprising. Called from `stop()` only.
    private func cancelAllPendingVisuals() {
        guard !pendingVisuals.isEmpty else { return }
        let cancelled = pendingVisuals.count
        pendingVisuals.removeAll()
        logger.info("visual: cancelled \(cancelled) pending visual(s) due to stop")
    }

    /// Attempts to flush the buffer eagerly for the first utterance.
    /// Flushes at the first sentence/clause boundary once the buffer reaches
    /// `eagerFlushChars`, or at any sentence boundary regardless of length.
    private func tryEagerFlush() {
        let cleaned = stripMarkdown(streamBuffer)

        // Try to find a sentence boundary first (works at any length)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let sentenceMatches = Self.sentencePattern.matches(in: cleaned, options: [], range: range)

        if let lastMatch = sentenceMatches.last {
            let splitIndex = cleaned.index(
                cleaned.startIndex,
                offsetBy: lastMatch.range.location + lastMatch.range.length
            )
            let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(cleaned[splitIndex...])
            streamBuffer = remainder
            hasFlushedFirst = true
            if !toSpeak.isEmpty {
                enqueueSentences(from: toSpeak)
            }
            return
        }

        // No sentence boundary yet — try clause boundary if we have enough text
        guard cleaned.count >= Self.eagerFlushChars else { return }

        // swiftlint:disable:next force_try
        let clausePattern = try! NSRegularExpression(pattern: "[,;:—–]\\s+", options: [])
        let clauseMatches = clausePattern.matches(in: cleaned, options: [], range: range)

        if let lastClause = clauseMatches.last {
            let splitIndex = cleaned.index(
                cleaned.startIndex,
                offsetBy: lastClause.range.location + lastClause.range.length
            )
            let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(cleaned[splitIndex...])
            streamBuffer = remainder
            hasFlushedFirst = true
            if !toSpeak.isEmpty {
                enqueueSentences(from: toSpeak)
            }
            return
        }

        // No boundaries at all — hard flush everything we have
        let toSpeak = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        streamBuffer = ""
        hasFlushedFirst = true
        if !toSpeak.isEmpty {
            enqueueSentences(from: toSpeak)
        }
    }

    /// Restarts the idle-flush timer. Fires when tokens stop arriving for `flushDelay`
    /// (between sentences, before tool calls, or at end of response).
    private func scheduleFlush() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushBuffer()
            }
        }
    }

    /// Forces any buffered text to be spoken immediately (e.g. before a tool call pause).
    /// Skips tiny fragments unless the stream has ended to avoid choppy mid-sentence breaks.
    func flushBuffer() {
        guard isStreaming else { return }
        let text = stripMarkdown(streamBuffer).trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip flushing tiny fragments while more text is still streaming —
        // let the buffer grow until a sentence boundary or end-of-stream.
        if text.count < Self.minFragmentLength, !streamEnded {
            return
        }

        logger.info("flushBuffer — text: \(text.prefix(80), privacy: .public)")
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
        flushTimer?.invalidate()
        flushTimer = nil

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

        flushTimer?.invalidate()
        flushTimer = nil

        for task in generationTasks {
            task.cancel()
        }
        generationTasks.removeAll()
        orderedSlots.removeAll()
        slotWatermarks.removeAll()
        bufferQueueWatermarks.removeAll()
        playingBufferWatermark = 0

        stopPlayback()

        // Release any tool awaiting `awaitSpokenChars` — audio will never
        // resume, so the tool should be free to proceed (or be cancelled).
        releaseAllBarrierWaiters()
        // Cancel (don't fire) pending visuals — session was stopped by
        // the user; firing stale cursors would be surprising UX.
        cancelAllPendingVisuals()

        if wasSpeaking {
            let cb = streamCompletion
            streamCompletion = nil
            cb?()
        }
    }

    /// Stops playback and the audio engine. Called when the panel is dismissed
    /// to fully release audio resources and prevent zombie engine instances.
    func shutdown() {
        stop()
        stopEngine()
    }

    private func stopPlayback() {
        bufferQueue.removeAll()
        bufferQueueWatermarks.removeAll()
        isPlaying = false
        playerNode.stop()
    }

    // Helper converters for the Kokoro pipeline result.
    fileprivate typealias KokoroResult = KokoroManager.GenerationResult

    /// Stops the audio engine to fully release audio resources.
    /// The engine is restarted automatically by `ensureEngineRunning` when needed.
    private func stopEngine() {
        guard engineStarted else { return }
        audioEngine.stop()
        audioEngine.reset()
        engineStarted = false
        logger.debug("Audio engine stopped and reset")
    }

    // MARK: - Audio Engine Management

    /// Pre-warms the audio engine so the first buffer doesn't get clipped.
    /// Called at the start of a streaming session before any audio is ready.
    private func prewarmEngine() {
        // Use a standard format to get the engine running early
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        ensureEngineRunning(format: format)
    }

    private func ensureEngineRunning(format: AVAudioFormat) {
        if !engineStarted {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
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

    /// Clause-boundary pattern: comma, semicolon, colon, em/en dash followed
    /// by whitespace. Used for mid-sentence draining once the buffer gets big
    /// enough to avoid dead air waiting for sentence-ending punctuation.
    // swiftlint:disable:next force_try
    private static let clausePattern = try! NSRegularExpression(
        pattern: "[,;:—–]\\s+",
        options: []
    )

    /// Extracts complete sentences from the buffer and enqueues them for speech.
    /// If no sentence boundary is present but the buffer has grown past
    /// `clauseFlushChars`, we fall back to draining at the latest clause
    /// boundary. This keeps Kokoro continuously fed during long sentences and
    /// prevents playback from outrunning generation (dead air).
    private func drainSentences() {
        let cleaned = stripMarkdown(streamBuffer)
        let range = NSRange(cleaned.startIndex..., in: cleaned)

        // Prefer sentence boundaries when available.
        if let lastMatch = Self.sentencePattern.matches(in: cleaned, range: range).last {
            drainAt(boundaryEnd: lastMatch.range.location + lastMatch.range.length, cleaned: cleaned, kind: "sentence")
            return
        }

        // No sentence boundary yet — drain at last clause boundary once buffer
        // has enough content that generation latency would bite.
        guard cleaned.count >= Self.clauseFlushChars,
              let lastClause = Self.clausePattern.matches(in: cleaned, range: range).last
        else { return }
        drainAt(boundaryEnd: lastClause.range.location + lastClause.range.length, cleaned: cleaned, kind: "clause")
    }

    /// Drains the buffer up to (and including) the given boundary index.
    private func drainAt(boundaryEnd: Int, cleaned: String, kind: String) {
        let splitIndex = cleaned.index(cleaned.startIndex, offsetBy: boundaryEnd)
        let toSpeak = String(cleaned[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(cleaned[splitIndex...])
        streamBuffer = remainder
        logger
            .info(
                "drain(\(kind, privacy: .public)) — spoke: \(toSpeak.prefix(80), privacy: .public), remainder: \(remainder.prefix(40), privacy: .public)"
            )
        if !toSpeak.isEmpty {
            enqueueSentences(from: toSpeak)
        }
    }

    // MARK: - Utterance Creation

    /// Splits text into speakable chunks, merges short fragments, and enqueues each.
    private func enqueueSentences(from text: String) {
        logger.info("enqueueSentences input: \(text.prefix(120), privacy: .public)")
        let sentences = splitIntoSentences(text)
        let chunks = splitLongSentences(sentences)
        let merged = mergeShortFragments(chunks)

        for (i, chunk) in merged.enumerated() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            logger.info("  chunk[\(i)]: \(trimmed.prefix(100), privacy: .public)")
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

    /// Enqueues text for TTS generation via Kokoro.
    private func enqueueUtterance(_ text: String) {
        pendingUtterances += 1
        logger.info("Enqueuing: \(text.prefix(60))…")

        if !firstChunkEnqueuedFired {
            firstChunkEnqueuedFired = true
            onFirstChunkEnqueued?()
        }

        let manager = KokoroManager.shared
        guard manager.isDownloaded else {
            logger.warning("Kokoro not downloaded, skipping: \(text.prefix(40))…")
            // No audio will play — still advance the barrier to this watermark
            // so tools waiting on it don't hang.
            advanceSpokenChars(to: inputCharsFed)
            utteranceDidFinish()
            return
        }

        guard let snapshot = manager.captureGenerationContext() else {
            logger.warning("No voice/engine available, skipping: \(text.prefix(40))…")
            advanceSpokenChars(to: inputCharsFed)
            utteranceDidFinish()
            return
        }

        let slot = nextSlotIndex
        nextSlotIndex += 1
        // Snapshot the char watermark so we can advance `inputCharsSpoken`
        // when this slot's audio finishes playing. See `awaitSpokenChars`.
        slotWatermarks[slot] = inputCharsFed

        let task = Task {
            let result: KokoroResult? = await withCheckedContinuation { continuation in
                self.generationQueue.async {
                    let gen = KokoroManager.generateAudioBufferOffMain(text: text, context: snapshot)
                    continuation.resume(returning: gen)
                }
            }

            guard !Task.isCancelled else { return }

            if let result {
                let item = PlaybackItem(buffer: result.buffer, wordTimings: result.wordTimings)
                self.slotReady(slot: slot, item: item)
            } else {
                logger.warning("Kokoro generation failed, skipping: \(text.prefix(40))…")
                self.slotFailed(slot: slot)
            }
        }
        generationTasks.append(task)
    }

    // MARK: - Ordered Slot Management

    /// Called when a TTS generation completes — stores the item in its ordered slot
    /// and drains any consecutive ready slots into the playback queue.
    private func slotReady(slot: Int, item: PlaybackItem) {
        orderedSlots[slot] = item
        if !firstAudioReadyFired {
            firstAudioReadyFired = true
            onFirstAudioReady?()
        }
        drainReadySlots()
    }

    /// Called when a TTS generation fails — skips this slot and drains.
    private func slotFailed(slot: Int) {
        utteranceDidFinish()
        // Still honour this slot's watermark so barrier waiters don't hang.
        if let watermark = slotWatermarks.removeValue(forKey: slot) {
            advanceSpokenChars(to: watermark)
        }
        // Mark slot as processed by advancing past it if it's next in line
        if slot == nextPlaySlot {
            nextPlaySlot += 1
            drainReadySlots()
        }
    }

    /// Drains consecutive ready slots into the playback buffer queue in order.
    private func drainReadySlots() {
        while let item = orderedSlots[nextPlaySlot] {
            orderedSlots.removeValue(forKey: nextPlaySlot)
            let watermark = slotWatermarks.removeValue(forKey: nextPlaySlot) ?? inputCharsFed
            nextPlaySlot += 1
            bufferQueue.append(item)
            bufferQueueWatermarks.append(watermark)
            playNextBuffer()
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

        // If we underran (queue emptied while more utterances were pending),
        // the gap between underrun and this call is audible dead air.
        if let underranAt = playbackUnderrunAt {
            let gap = Date().timeIntervalSince(underranAt)
            onPlaybackGap?(gap)
            playbackUnderrunAt = nil
        }

        isPlaying = true

        let item = bufferQueue.removeFirst()
        let watermark = bufferQueueWatermarks.isEmpty ? inputCharsFed : bufferQueueWatermarks.removeFirst()
        playingBufferWatermark = watermark
        ensureEngineRunning(format: item.buffer.format)

        if !firstAudioPlaybackFired {
            firstAudioPlaybackFired = true
            onFirstAudioPlayback?()
        }

        // Word-level visual sync: NOW is the moment this buffer's audio
        // becomes audible (approximately — AVAudioEngine's output latency
        // is typically <20ms, well below perceptual threshold). Pair each
        // pending visual with a word timing in this buffer and fire it
        // via asyncAfter at the exact word offset.
        let bufferStartTime = CACurrentMediaTime()
        schedulePendingVisualsForItem(item, bufferStartTime: bufferStartTime)

        // Use `.dataPlayedBack` so the completion fires AFTER the audio has
        // actually been output through the hardware — not when the buffer is
        // merely consumed from the render queue (which happens 100-300ms
        // earlier). This is critical for voice/visual sync: without it,
        // `inputCharsSpoken` ticks up before the user has heard the
        // narration, and tool_use fires early. Matches the pattern used by
        // LiveKit, mlx-swift-audio, WhisperKit, and QwenVoice.
        playerNode.scheduleBuffer(item.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                // Advance the spoken-chars counter NOW that this buffer has
                // actually played — any visual tool barrier ≤ watermark can
                // fire on the very next runloop tick.
                self.advanceSpokenChars(to: watermark)
                self.utteranceDidFinish()

                if !self.bufferQueue.isEmpty {
                    self.playNextBuffer()
                } else if self.pendingUtterances > 0, self.isStreaming {
                    // Buffer queue is empty but more text is on its way and we
                    // haven't finished streaming. Record an underrun; the next
                    // playNextBuffer() will report the gap.
                    self.playbackUnderrunAt = Date()
                }
            }
        }
        playerNode.play()
    }

    private func completeStream() {
        isStreaming = false
        streamEnded = false
        // All audio has played — mark spoken == fed and release any lingering
        // barrier waiters (shouldn't be any if the math is right, but belt).
        if inputCharsFed > inputCharsSpoken {
            advanceSpokenChars(to: inputCharsFed)
        }
        releaseAllBarrierWaiters()
        // Stream ended naturally — fire any pending visuals whose label
        // never appeared in the narration. Better to show the cursor late
        // than never show it at all.
        fireAllPendingVisuals()
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
