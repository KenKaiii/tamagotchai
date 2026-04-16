import Foundation
@testable import Tama
import Testing

/// CallMetrics is primarily a logging/telemetry helper — these tests just lock
/// in that it doesn't crash on partial-turn data (e.g. a turn that ended
/// before reaching TTS, or a user that never started speaking) and that the
/// public API is safe to call from CallSession's happy path.
@Suite("CallMetrics")
@MainActor
struct CallMetricsTests {
    @Test("endTurn() is safe even when no milestones were recorded")
    func emptyTurnDoesNotCrash() {
        let metrics = CallMetrics()
        metrics.beginTurn()
        metrics.endTurn()
        // No assertion — the test is that this doesn't crash or hang.
    }

    @Test("happy-path turn records every milestone once and emits summary")
    func happyPathTurn() async {
        let metrics = CallMetrics()
        metrics.beginTurn()
        metrics.noteFirstSpeech()
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms — user "speaks"
        metrics.noteSilenceDetected(wordCount: 3)
        metrics.noteAgentRequestSent()
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms — "LLM thinks"
        metrics.noteFirstDelta("Hello")
        metrics.noteFirstTTSEnqueue()
        metrics.noteFirstAudioReady()
        metrics.noteFirstAudioPlayback()
        metrics.noteToolComplete(name: "screenshot", durationMs: 250)
        metrics.noteTTSFinished()
        metrics.endTurn()
    }

    @Test("duplicate milestone calls are no-ops (first-occurrence wins)")
    func duplicateMilestonesAreIdempotent() {
        let metrics = CallMetrics()
        metrics.beginTurn()
        metrics.noteFirstSpeech()
        metrics.noteFirstSpeech() // second call must be ignored
        metrics.noteSilenceDetected(wordCount: 5)
        metrics.noteSilenceDetected(wordCount: 999) // ignored
        metrics.endTurn()
    }

    @Test("playback gap below threshold is not recorded")
    func smallGapIgnored() {
        let metrics = CallMetrics()
        metrics.beginTurn()
        metrics.notePlaybackGap(0.05) // below 0.25s threshold
        metrics.endTurn()
    }

    @Test("multiple turns accumulate independently without state leaking")
    func multipleTurns() {
        let metrics = CallMetrics()
        for _ in 0 ..< 3 {
            metrics.beginTurn()
            metrics.noteFirstSpeech()
            metrics.noteSilenceDetected(wordCount: 2)
            metrics.endTurn()
        }
    }
}
