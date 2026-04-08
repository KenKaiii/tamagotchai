import AVFoundation
import Speech
import SwiftUI

struct PermissionsView: View {
    @State private var accessibilityGranted = false
    @State private var fullDiskAccessGranted = false
    @State private var microphoneGranted = false
    @State private var speechGranted = false
    @State private var appManagementGranted = false
    @State private var notificationsGranted = false
    @State private var permissionPollTimer: Timer?

    @ObservedObject private var chromium = ChromiumManager.shared
    private let checker = PermissionsChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("Permissions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.top, 10)
                .padding(.bottom, 8)

            VStack(spacing: 1) {
                permissionRow(
                    title: "Accessibility",
                    description: "Required for the global hotkey (⌥Space).",
                    granted: accessibilityGranted,
                    action: {
                        if accessibilityGranted {
                            checker.openAccessibilitySettings()
                        } else {
                            checker.requestAccessibility()
                        }
                    }
                )

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Full Disk Access",
                    description: fullDiskAccessGranted
                        ? "Required to read, write, and edit files."
                        : "Click Open Settings, then press '+' and add Tama.",
                    granted: fullDiskAccessGranted,
                    action: {
                        checker.openFullDiskAccessSettings()
                        checker.revealAppInFinder()
                    }
                )

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Microphone",
                    description: "Required for voice input (hold ⌥Space).",
                    granted: microphoneGranted,
                    action: {
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                            checker.requestMicrophone { granted in
                                microphoneGranted = granted
                            }
                        } else {
                            checker.openMicrophoneSettings()
                        }
                    }
                )

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Speech Recognition",
                    description: "Required for voice-to-text transcription.",
                    granted: speechGranted,
                    action: {
                        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                            checker.requestSpeechRecognition { status in
                                speechGranted = status == .authorized
                            }
                        } else {
                            checker.openMicrophoneSettings()
                        }
                    }
                )

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "App Management",
                    description: appManagementGranted
                        ? "Allows managing the bundled browser."
                        : "Required for browser download. Open Settings and toggle on.",
                    granted: appManagementGranted,
                    action: {
                        checker.openAppManagementSettings()
                    }
                )

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Notifications",
                    description: "Required for reminders and routine alerts.",
                    granted: notificationsGranted,
                    action: {
                        let status = checker.notificationsStatus()
                        if status == .notDetermined {
                            // First time - request authorization (shows system dialog)
                            checker.requestNotifications { newStatus in
                                notificationsGranted = newStatus == .authorized
                            }
                        } else {
                            // Already decided - open system settings
                            checker.openNotificationsSettings()
                        }
                    }
                )

                Divider().opacity(0.3).padding(.horizontal, 14)

                browserRow
            }

            Divider().opacity(0.3)
                .padding(.top, 8)

            HStack(spacing: 8) {
                GlassButton("Refresh") {
                    refreshStatuses()
                }
                Spacer()
                GlassButton("Done", isPrimary: true) {
                    PermissionsWindowController.dismiss()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    private func startPermissionPolling() {
        // Initial check with delay to ensure system returns correct status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshStatuses()
        }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                refreshStatuses()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private var hasBrowser: Bool {
        BrowserManager.installedSystemBrowser != nil || chromium.isDownloaded
    }

    private var browserDescription: String {
        if chromium.isDownloaded {
            return "Chrome for Testing is ready."
        }
        if let name = BrowserManager.installedSystemBrowser {
            return "\(name) detected."
        }
        return "~400 MB download for web browsing tools."
    }

    private var browserRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browser (Optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(browserDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            if hasBrowser {
                Text("Ready")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            } else if chromium.isDownloading {
                ProgressView(value: chromium.downloadProgress)
                    .frame(width: 60)
                    .tint(.white.opacity(0.6))
                    .scaleEffect(y: 0.5)
            } else {
                GlassButton("Download") { chromium.downloadChromium() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func refreshStatuses() {
        accessibilityGranted = checker.isAccessibilityGranted()
        fullDiskAccessGranted = checker.isFullDiskAccessGranted()
        microphoneGranted = checker.isMicrophoneGranted()
        speechGranted = checker.isSpeechRecognitionGranted()
        appManagementGranted = checker.isAppManagementGranted()
        notificationsGranted = checker.isNotificationsGranted()
    }

    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            } else {
                GlassButton("Grant") { action() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
