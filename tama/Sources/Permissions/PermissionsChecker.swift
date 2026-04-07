import AppKit
import ApplicationServices
import AVFoundation
import os
import Speech

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "permissions"
)

// MARK: - Non-isolated permission request helpers

/// These free functions live outside the @MainActor class so their closures
/// are not implicitly MainActor-isolated. The system calls the completion
/// handler on an arbitrary thread; we dispatch back to main before invoking
/// the caller's callback.

private func requestMicrophoneAccess(completion: (@Sendable @MainActor (Bool) -> Void)?) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
            logger.info("Microphone permission response: \(granted ? "granted" : "denied")")
            completion?(granted)
        }
    }
}

private func requestSpeechAccess(
    completion: (@Sendable @MainActor (SFSpeechRecognizerAuthorizationStatus) -> Void)?
) {
    SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
            logger.info("Speech recognition permission response: \(status.rawValue)")
            completion?(status)
        }
    }
}

// MARK: - PermissionsChecker

@MainActor
final class PermissionsChecker {
    static let shared = PermissionsChecker()
    private init() {}

    // MARK: - Accessibility

    /// The AXTrustedCheckOptionPrompt key, extracted once to avoid Swift 6 concurrency warnings
    /// on the global `kAXTrustedCheckOptionPrompt`.
    private let axTrustedPromptKey = "AXTrustedCheckOptionPrompt"

    func isAccessibilityGranted() -> Bool {
        // AXIsProcessTrusted() can return false for ad-hoc signed builds even when
        // accessibility is actually working. Use AXIsProcessTrustedWithOptions as a
        // secondary check without prompting.
        var granted = AXIsProcessTrusted()
        if !granted {
            let options = [axTrustedPromptKey: false] as CFDictionary
            granted = AXIsProcessTrustedWithOptions(options)
        }
        logger.info("Accessibility permission check: \(granted ? "granted" : "denied")")
        return granted
    }

    /// Prompts the user to grant Accessibility permission (shows system dialog).
    func requestAccessibility() {
        let options = [axTrustedPromptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Full Disk Access

    func isFullDiskAccessGranted() -> Bool {
        let granted = FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        logger.info("Full Disk Access permission check: \(granted ? "granted" : "denied")")
        return granted
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone

    func isMicrophoneGranted() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted = status == .authorized
        logger.info("Microphone permission check: \(granted ? "granted" : "denied") (status: \(status.rawValue))")
        return granted
    }

    func requestMicrophone(completion: (@MainActor (Bool) -> Void)? = nil) {
        requestMicrophoneAccess(completion: completion)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Speech Recognition

    func isSpeechRecognitionGranted() -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        let granted = status == .authorized
        logger
            .info("Speech recognition permission check: \(granted ? "granted" : "denied") (status: \(status.rawValue))")
        return granted
    }

    func requestSpeechRecognition(
        completion: (@MainActor (SFSpeechRecognizerAuthorizationStatus) -> Void)? = nil
    ) {
        requestSpeechAccess(completion: completion)
    }

    // MARK: - App Management

    /// Checks if App Management permission is granted by attempting a test
    /// operation on a temporary .app bundle inside Application Support.
    func isAppManagementGranted() -> Bool {
        let testDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tama/.appmanagement-check")
        let testApp = testDir.appendingPathComponent("Test.app")
        let testFile = testApp.appendingPathComponent("Contents/Info.plist")

        do {
            try FileManager.default.createDirectory(
                at: testApp.appendingPathComponent("Contents"),
                withIntermediateDirectories: true
            )
            try Data().write(to: testFile)
            try FileManager.default.removeItem(at: testDir)
            logger.info("App Management permission check: granted")
            return true
        } catch {
            try? FileManager.default.removeItem(at: testDir)
            logger.info("App Management permission check: denied (\(error.localizedDescription))")
            return false
        }
    }

    func openAppManagementSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    /// Reveals the app bundle in Finder so the user can drag it into System Settings.
    func revealAppInFinder() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
}
