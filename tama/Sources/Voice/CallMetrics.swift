import Foundation
import os

/// Per-turn telemetry accumulator for voice calls.
///
/// Records named timestamps for each phase of a user↔agent turn
/// (listen → silence → agent → TTS → playback) and emits a compact summary
/// at turn end. Anything slower than a configured threshold is flagged with a
/// visible ⚠️ prefix so speed regressions jump out in Console.app.
///
/// Log category `callmetrics` lets you isolate these summaries from noisy
/// pipeline logs:
///
///     log stream --predicate 'subsystem == "com.unstablemind.tama" \
///                             AND category == "callmetrics"' --style compact
@MainActor
final class CallMetrics {
    private let logger = Logger(
        subsystem: "com.unstablemind.tama",
        category: "callmetrics"
    )

    // MARK: - Thresholds

    // Values tuned for "real phone-call feel". Tweak if the UX bar shifts.

    /// Max comfortable gap from user stopping → us detecting end of speech.
    private let slowSilenceDetect: TimeInterval = 1.2
    /// Max comfortable LLM time-to-first-token. Cloud providers over typical
    /// US broadband realistically land at 1.0–1.4s cold — anything higher is
    /// a genuine problem (throttling, huge context, etc.).
    private let slowAgentTTFB: TimeInterval = 1.5
    /// Max time from first TTS enqueue → first audio buffer ready.
    private let slowFirstAudioReady: TimeInterval = 0.8
    /// Max end-to-end from user finishing → user hearing agent's first word.
    private let slowE2E: TimeInterval = 2.0
    /// Any mid-stream playback gap > this is logged as dead-air.
    private let deadAirThreshold: TimeInterval = 0.25

    // MARK: - State

    private var turnNumber = 0

    // Milestones. `nil` means "not reached this turn yet".
    private var tTurnStart: Date?
    private var tFirstSpeech: Date?
    private var tSilenceDetected: Date?
    private var tAgentRequest: Date?
    private var tFirstDelta: Date?
    private var tFirstTTSEnqueue: Date?
    private var tFirstAudioReady: Date?
    private var tFirstAudioPlayback: Date?
    private var tTTSFinished: Date?
    private var tTurnEnd: Date?

    // Aggregates
    private var deltaCount = 0
    private var deltaCharCount = 0
    private var toolCalls: [(name: String, ms: Int)] = []
    private var deadAirEvents: [TimeInterval] = []

    init() {}

    // MARK: - Turn Lifecycle

    /// Called by `CallSession` when it starts listening for the next user turn.
    func beginTurn() {
        turnNumber += 1
        tTurnStart = Date()
        tFirstSpeech = nil
        tSilenceDetected = nil
        tAgentRequest = nil
        tFirstDelta = nil
        tFirstTTSEnqueue = nil
        tFirstAudioReady = nil
        tFirstAudioPlayback = nil
        tTTSFinished = nil
        tTurnEnd = nil
        deltaCount = 0
        deltaCharCount = 0
        toolCalls.removeAll()
        deadAirEvents.removeAll()
        let msg = "━━━━━━━━━━━━━━━━━━ TURN \(turnNumber) LISTEN ━━━━━━━━━━━━━━━━━━"
        logger.info("\(msg, privacy: .public)")
    }

    /// First RMS crossing the speech threshold in this turn.
    func noteFirstSpeech() {
        guard tFirstSpeech == nil else { return }
        tFirstSpeech = Date()
        let msg = "🎤 User started speaking (\(since(tTurnStart)))"
        logger.info("\(msg, privacy: .public)")
    }

    /// `VoiceService` finalized a transcript (silence detected).
    func noteSilenceDetected(wordCount: Int) {
        guard tSilenceDetected == nil else { return }
        tSilenceDetected = Date()
        let elapsed = format(timeInterval(from: tFirstSpeech, to: tSilenceDetected))
        let msg = "🔇 Silence detected (\(wordCount) words, user spoke for \(elapsed)s)"
        logger.info("\(msg, privacy: .public)")
    }

    /// Agent HTTP request went out (start of `sendWithTools`).
    func noteAgentRequestSent() {
        guard tAgentRequest == nil else { return }
        tAgentRequest = Date()
        let gap = format(timeInterval(from: tSilenceDetected, to: tAgentRequest))
        let msg = "🧠 Agent request sent (silence→request: \(gap)s)"
        logger.info("\(msg, privacy: .public)")
    }

    /// First text delta from the LLM — critical "time to first token".
    func noteFirstDelta(_ text: String) {
        deltaCount += 1
        deltaCharCount += text.count
        guard tFirstDelta == nil else { return }
        tFirstDelta = Date()
        let ttfb = timeInterval(from: tAgentRequest, to: tFirstDelta) ?? 0
        let ttfbStr = format(ttfb)
        let threshStr = format(slowAgentTTFB)
        if ttfb > slowAgentTTFB {
            let msg = "⚠️  SLOW Agent TTFB: \(ttfbStr)s (threshold \(threshStr)s)"
            logger.warning("\(msg, privacy: .public)")
        } else {
            let msg = "⚡️ First LLM token after \(ttfbStr)s"
            logger.info("\(msg, privacy: .public)")
        }
    }

    /// A tool finished. Recorded as part of the turn's aggregate timing.
    func noteToolComplete(name: String, durationMs: Int) {
        toolCalls.append((name, durationMs))
        logger.info("🛠  Tool \(name, privacy: .public) — \(durationMs)ms")
    }

    /// `SpeechService` started generating the first TTS buffer of this turn.
    func noteFirstTTSEnqueue() {
        guard tFirstTTSEnqueue == nil else { return }
        tFirstTTSEnqueue = Date()
        let gap = format(timeInterval(from: tFirstDelta, to: tFirstTTSEnqueue))
        let msg = "🗣  First TTS chunk enqueued (delta→enqueue: \(gap)s)"
        logger.info("\(msg, privacy: .public)")
    }

    /// First Kokoro buffer ready in the play queue (not yet playing).
    func noteFirstAudioReady() {
        guard tFirstAudioReady == nil else { return }
        tFirstAudioReady = Date()
        let gap = timeInterval(from: tFirstTTSEnqueue, to: tFirstAudioReady) ?? 0
        let gapStr = format(gap)
        let threshStr = format(slowFirstAudioReady)
        if gap > slowFirstAudioReady {
            let msg = "⚠️  SLOW TTS gen: \(gapStr)s (threshold \(threshStr)s)"
            logger.warning("\(msg, privacy: .public)")
        } else {
            let msg = "🎵 First audio buffer ready (\(gapStr)s)"
            logger.info("\(msg, privacy: .public)")
        }
    }

    /// User starts actually hearing the agent's voice — the critical UX moment.
    func noteFirstAudioPlayback() {
        guard tFirstAudioPlayback == nil else { return }
        tFirstAudioPlayback = Date()
        let e2e = timeInterval(from: tSilenceDetected, to: tFirstAudioPlayback) ?? 0
        let e2eStr = format(e2e)
        let threshStr = format(slowE2E)
        if e2e > slowE2E {
            let msg = "⚠️  SLOW E2E user→voice: \(e2eStr)s (threshold \(threshStr)s)"
            logger.warning("\(msg, privacy: .public)")
        } else {
            let msg = "🎯 E2E user→voice: \(e2eStr)s"
            logger.info("\(msg, privacy: .public)")
        }
    }

    /// Detected a gap in playback (queue went empty while stream still active).
    func notePlaybackGap(_ seconds: TimeInterval) {
        guard seconds >= deadAirThreshold else { return }
        deadAirEvents.append(seconds)
        let gap = format(seconds)
        let msg = "⚠️  Dead air: \(gap)s gap between TTS buffers"
        logger.warning("\(msg, privacy: .public)")
    }

    /// TTS fully drained — nothing left to say.
    func noteTTSFinished() {
        guard tTTSFinished == nil else { return }
        tTTSFinished = Date()
    }

    /// End-of-turn summary. Call this after TTS has drained and we're about to
    /// start listening again (or after `end_call`).
    func endTurn() {
        tTurnEnd = Date()
        emitSummary()
    }

    // MARK: - Summary

    private func emitSummary() {
        // User's actual speech duration, excluding the trailing silence window.
        let userSpoke = interval(tFirstSpeech, tSilenceDetected)
        // Time from detecting silence → HTTP request actually going out. Should
        // be near-zero; any non-trivial value points to a handoff bottleneck
        // (e.g. main-thread work between VoiceService callback and runAgent).
        let silenceToRequest = interval(tSilenceDetected, tAgentRequest)
        let agentTTFB = interval(tAgentRequest, tFirstDelta)
        let agentTotal = interval(tAgentRequest, tFirstTTSEnqueue ?? tTTSFinished)
        let ttsGen = interval(tFirstTTSEnqueue, tFirstAudioReady)
        let ttsWait = interval(tFirstAudioReady, tFirstAudioPlayback)
        let e2e = interval(tSilenceDetected, tFirstAudioPlayback)
        let total = interval(tTurnStart, tTurnEnd)
        let toolsTotal = toolCalls.reduce(0) { $0 + $1.ms }
        let deadAirTotal = deadAirEvents.reduce(0, +)

        // A single multi-line log keeps the summary contiguous in Console.app.
        // Each number is a separate line for readability; "—" when not captured.
        var lines: [String] = []
        lines.append("━━━━━━━━━━━━━ TURN \(turnNumber) SUMMARY ━━━━━━━━━━━━━")
        lines.append("  User spoke ............ \(format(userSpoke))s")
        lines.append("  Silence→request ....... \(format(silenceToRequest))s")
        lines
            .append("  Agent TTFB ............ \(format(agentTTFB))s   (\(deltaCount) deltas, \(deltaCharCount) chars)")
        lines.append("  Agent total ........... \(format(agentTotal))s")
        if !toolCalls.isEmpty {
            let toolSummary = toolCalls.map { "\($0.name)=\($0.ms)ms" }.joined(separator: ", ")
            lines.append("  Tools (\(toolCalls.count)) \(toolsTotal)ms ....... \(toolSummary)")
        }
        lines.append("  TTS gen (first chunk) . \(format(ttsGen))s")
        lines.append("  TTS ready→playback .... \(format(ttsWait))s")
        if !deadAirEvents.isEmpty {
            lines.append("  ⚠️  Dead air events .... \(deadAirEvents.count) (total \(format(deadAirTotal))s)")
        }
        lines.append("  🎯 E2E user→voice ..... \(format(e2e))s")
        lines.append("  Turn total ............ \(format(total))s")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        for line in lines {
            logger.info("\(line, privacy: .public)")
        }
    }

    // MARK: - Formatting

    private func format(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.2f", seconds)
    }

    private func since(_ start: Date?) -> String {
        guard let start else { return "—" }
        return format(Date().timeIntervalSince(start)) + "s"
    }

    private func timeInterval(from: Date?, to: Date?) -> TimeInterval? {
        guard let from, let to else { return nil }
        return to.timeIntervalSince(from)
    }

    /// Interval helper aliased for readability in `emitSummary`.
    private func interval(_ a: Date?, _ b: Date?) -> TimeInterval? {
        timeInterval(from: a, to: b)
    }
}
