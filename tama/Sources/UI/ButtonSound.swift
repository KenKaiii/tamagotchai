import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "sound"
)

/// Plays the shared button click sound. Uses NSSound for reliable playback in menu-bar apps.
final class ButtonSound: NSObject, NSSoundDelegate, @unchecked Sendable {
    static let shared = ButtonSound()

    private var sound: NSSound?

    override private init() {
        super.init()
        guard let url = Bundle.main.url(forResource: "sound-step", withExtension: "mp3") else {
            logger.error("sound-step.mp3 not found in bundle")
            return
        }
        sound = NSSound(contentsOf: url, byReference: true)
        sound?.delegate = self
        logger.debug("ButtonSound loaded")
    }

    func play() {
        guard let sound else {
            logger.warning("ButtonSound play called but sound is nil")
            return
        }
        // Stop any in-progress playback so we can replay immediately
        sound.stop()
        sound.play()
    }
}
