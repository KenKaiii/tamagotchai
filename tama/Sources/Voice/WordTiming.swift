import Foundation
import MLXUtilsLibrary

/// Per-word timing information aligned to a single generated audio buffer.
/// Produced by Kokoro's `duration_proj` (via `TimestampPredictor`) and used
/// by `SpeechService` to fire visual cursors at the exact moment a specific
/// word is spoken, rather than at coarser chunk or stream boundaries.
///
/// Both `startSec` and `endSec` are relative to the START of the audio
/// buffer they accompany — NOT to the whole streaming session. The buffer's
/// own playback start (wall-clock) is combined with these offsets in
/// `SpeechService` to schedule fire-at-word actions.
struct WordTiming: Sendable {
    /// The word's surface text as emitted by Kokoro's G2P. Trailing
    /// whitespace / punctuation is not included; the raw token text.
    let text: String
    /// Seconds from the buffer's audio start to the moment this word
    /// begins being uttered.
    let startSec: Double
    /// Seconds from the buffer's audio start to the moment this word
    /// finishes being uttered.
    let endSec: Double
}

extension [MToken] {
    /// Convert a Kokoro `[MToken]` array into our domain `WordTiming`
    /// structs. Tokens without populated timestamps (typically whitespace-
    /// only or punctuation entries) are dropped — they never match a
    /// visual's label so carrying them forward is just noise.
    func toWordTimings() -> [WordTiming] {
        compactMap { token in
            guard let start = token.start_ts, let end = token.end_ts else { return nil }
            return WordTiming(text: token.text, startSec: start, endSec: end)
        }
    }
}
