import AVFoundation
import Speech
import SwiftUI

struct PermissionsView: View {
    @State private var accessibilityGranted = false
    @State private var fullDiskAccessGranted = false
    @State private var microphoneGranted = false
    @State private var speechGranted = false

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
                        : "Click Open Settings, then press '+' and add Tamagotchai.",
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
                            checker.requestMicrophone { _ in
                                refreshStatuses()
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
                            checker.requestSpeechRecognition { _ in
                                refreshStatuses()
                            }
                        } else {
                            checker.openMicrophoneSettings()
                        }
                    }
                )
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
        .onAppear { refreshStatuses() }
    }

    private func refreshStatuses() {
        accessibilityGranted = checker.isAccessibilityGranted()
        fullDiskAccessGranted = checker.isFullDiskAccessGranted()
        microphoneGranted = checker.isMicrophoneGranted()
        speechGranted = checker.isSpeechRecognitionGranted()
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
