import Foundation

/// TTS backend identifier. Currently only Kokoro (local) is supported.
enum TTSProvider {
    case kokoro

    // MARK: - Persistence

    /// The currently active TTS provider. Always Kokoro.
    static var active: TTSProvider { .kokoro }
}
