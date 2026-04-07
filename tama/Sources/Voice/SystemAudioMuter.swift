import CoreAudio
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "audio.mute"
)

/// Mutes and unmutes the system audio output device while voice capture is active,
/// preventing system sounds and music from being picked up by the microphone.
enum SystemAudioMuter: @unchecked Sendable {
    // Whether we muted the system and need to restore on stop.
    // Only accessed from VoiceService which serializes calls on the main thread.
    // swiftlint:disable:next modifier_order
    private(set) nonisolated(unsafe) static var didMute = false

    /// Mutes the default output device. Safe to call multiple times.
    static func muteSystemOutput() {
        guard !didMute else { return }
        guard let deviceID = defaultOutputDeviceID() else {
            logger.warning("No default output device found — skipping mute")
            return
        }

        if isMuted(deviceID: deviceID) {
            // Already muted by user — don't touch it and don't mark didMute
            // so we don't unmute something the user muted themselves.
            logger.info("System output already muted by user — leaving as-is")
            return
        }

        if setMute(deviceID: deviceID, muted: true) {
            didMute = true
            logger.info("Muted system audio output for voice capture")
        } else {
            logger.warning("Failed to mute system audio output")
        }
    }

    /// Unmutes the default output device, but only if we were the ones who muted it.
    static func unmuteSystemOutput() {
        guard didMute else { return }
        didMute = false

        guard let deviceID = defaultOutputDeviceID() else {
            logger.warning("No default output device found — skipping unmute")
            return
        }

        if setMute(deviceID: deviceID, muted: false) {
            logger.info("Restored system audio output after voice capture")
        } else {
            logger.warning("Failed to unmute system audio output")
        }
    }

    // MARK: - CoreAudio Helpers

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func isMuted(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)

        return status == noErr && muted != 0
    }

    private static func setMute(deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            logger.warning("Device does not support mute property")
            return false
        }

        var settable = DarwinBoolean(false)
        let checkStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard checkStatus == noErr, settable.boolValue else {
            logger.warning("Mute property is not settable on this device")
            return false
        }

        var muteValue: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muteValue)

        return status == noErr
    }
}
