import AVFoundation

/// Plays the shared button click sound. Preloads the audio for zero-latency playback.
final class ButtonSound: @unchecked Sendable {
    static let shared = ButtonSound()

    private var player: AVAudioPlayer?

    private init() {
        guard let url = Bundle.main.url(forResource: "sound-step", withExtension: "mp3") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }

    func play() {
        player?.currentTime = 0
        player?.play()
    }
}
