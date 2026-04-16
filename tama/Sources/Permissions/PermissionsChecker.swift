import AppKit
import ApplicationServices
import AVFoundation
import os
import Speech
import UserNotifications

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "permissions"
)

// MARK: - Authorization Status Helpers

extension UNAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}

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

    private init() {
        installAccessibilityObserver()
    }

    // Cached permission states to reduce log spam
    private var lastAccessibilityState: Bool?
    private var lastFullDiskState: Bool?
    private var lastMicrophoneState: Bool?
    private var lastSpeechState: Bool?
    private var lastAppManagementState: Bool?
    private var lastNotificationsState: UNAuthorizationStatus?
    private var lastScreenRecordingState: Bool?

    /// macOS posts `com.apple.accessibility.api` via `DistributedNotificationCenter`
    /// whenever ANY app's Accessibility permission state changes in System
    /// Settings. Subscribing lets us refresh our cached trust state the
    /// instant the user grants — without this, `AXIsProcessTrusted()`
    /// keeps returning its last-cached value inside the running process
    /// and users think the app "needs a restart". Pattern used by every
    /// production AX-dependent app: Loop, MonitorControl, CopilotForXcode,
    /// Squirrel, Informant, etc.
    private func installAccessibilityObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Short delay to let the AX daemon finalise the change before
            // we re-query — matches the 100ms used by Loop, Squirrel, Moves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self else { return }
                let previous = self.lastAccessibilityState
                let granted = AXIsProcessTrusted()
                if previous != granted {
                    self.lastAccessibilityState = granted
                    logger
                        .info(
                            "Accessibility permission changed (live): \(previous.map { $0 ? "granted" : "denied" } ?? "unknown") → \(granted ? "granted" : "denied")"
                        )
                }
            }
        }
    }

    // MARK: - Accessibility

    /// The AXTrustedCheckOptionPrompt key, extracted once to avoid Swift 6 concurrency warnings
    /// on the global `kAXTrustedCheckOptionPrompt`.
    private let axTrustedPromptKey = "AXTrustedCheckOptionPrompt"

    func isAccessibilityGranted() -> Bool {
        // Canonical API. If this returns false while the user believes
        // they've granted permission, the root cause is almost always a
        // binary-path / code-signature mismatch — macOS keys Accessibility
        // trust to the signed designated requirement, so a prior-granted
        // binary at a different path (release install, older DMG) counts as
        // a DIFFERENT app from the current Xcode-built Debug binary even
        // though the bundle ID matches. Fix by removing Tama from
        // System Settings › Privacy & Security › Accessibility and
        // re-adding the current binary.
        let granted = AXIsProcessTrusted()
        if lastAccessibilityState != granted {
            lastAccessibilityState = granted
            logger.info("Accessibility permission: \(granted ? "granted" : "denied")")
        }
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
        if lastFullDiskState != granted {
            lastFullDiskState = granted
            logger.info("Full Disk Access permission: \(granted ? "granted" : "denied")")
        }
        return granted
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Documents Folder

    private var lastDocumentsFolderState: Bool?

    /// Checks if the app can access ~/Documents by testing readability.
    func isDocumentsFolderGranted() -> Bool {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let granted = FileManager.default.isReadableFile(atPath: documentsURL.path)
        if lastDocumentsFolderState != granted {
            lastDocumentsFolderState = granted
            logger.info("Documents Folder permission: \(granted ? "granted" : "denied")")
        }
        return granted
    }

    /// Triggers the TCC prompt by accessing ~/Documents/Tama via ensureWorkspace().
    func requestDocumentsFolderAccess() {
        _ = PromptPanelController.ensureWorkspace()
    }

    func openFilesAndFoldersSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone

    func isMicrophoneGranted() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted = status == .authorized
        if lastMicrophoneState != granted {
            lastMicrophoneState = granted
            logger.info("Microphone permission: \(granted ? "granted" : "denied") (status: \(status.rawValue))")
        }
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
        if lastSpeechState != granted {
            lastSpeechState = granted
            logger.info("Speech recognition permission: \(granted ? "granted" : "denied") (status: \(status.rawValue))")
        }
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
            if lastAppManagementState != true {
                lastAppManagementState = true
                logger.info("App Management permission: granted")
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: testDir)
            if lastAppManagementState != false {
                lastAppManagementState = false
                logger.info("App Management permission: denied")
            }
            return false
        }
    }

    func openAppManagementSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Screen Recording

    /// Returns true if the app has Screen Recording permission. Uses
    /// `CGPreflightScreenCaptureAccess` so the system dialog is never shown.
    /// Note: this value is cached by the system within a process lifetime, so
    /// revocation may not be reflected until restart.
    func isScreenRecordingGranted() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if lastScreenRecordingState != granted {
            lastScreenRecordingState = granted
            logger.info("Screen Recording permission: \(granted ? "granted" : "denied")")
        }
        return granted
    }

    /// Triggers the system Screen Recording prompt the first time the app
    /// requests access. Returns true if access was already (or is now) granted.
    @discardableResult
    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Notifications

    /// Returns the current notification authorization status.
    func notificationsStatus() -> UNAuthorizationStatus {
        let semaphore = DispatchSemaphore(value: 0)
        var status: UNAuthorizationStatus = .notDetermined

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            status = settings.authorizationStatus
            semaphore.signal()
        }

        semaphore.wait()
        if lastNotificationsState != status {
            lastNotificationsState = status
            logger.info("Notifications permission: \(status.description)")
        }
        return status
    }

    func isNotificationsGranted() -> Bool {
        notificationsStatus() == .authorized
    }

    func requestNotifications(completion: (@MainActor (UNAuthorizationStatus) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error {
                    logger.error("Notifications permission error: \(error.localizedDescription)")
                }
                let status: UNAuthorizationStatus = granted ? .authorized : .denied
                logger.info("Notifications permission response: \(granted ? "granted" : "denied")")
                completion?(status)
            }
        }
    }

    func openNotificationsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    /// Reveals the app bundle in Finder so the user can drag it into System Settings.
    func revealAppInFinder() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
}
