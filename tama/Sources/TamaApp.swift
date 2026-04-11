import os
import SwiftUI
import UserNotifications

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "app"
)

@main
struct TamaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var isLoggedIn = ClaudeService.shared.isLoggedIn

    var body: some Scene {
        // Menu bar presence — the app lives in the menu bar
        MenuBarExtra {
            Button("Open Tama") {
                ButtonSound.shared.play()
                DropdownPanelController.closeAnyOpen()
                PromptPanelController.shared.toggle()
            }
            .keyboardShortcut(.space, modifiers: [.option])

            Button("Permissions…") {
                ButtonSound.shared.play()
                PermissionsWindowController.show()
            }

            Button("Voice Settings…") {
                ButtonSound.shared.play()
                VoiceSettingsController.show()
            }

            Button("Check for Updates…") {
                ButtonSound.shared.play()
                UpdateWindowController.show()
            }

            Divider()

            Button("AI Settings…") {
                ButtonSound.shared.play()
                LoginWindowController.show { isLoggedIn = $0 }
            }

            #if DEBUG
            Divider()

            Button("Test Notification") {
                ButtonSound.shared.play()
                TestNotificationCoordinator.shared.fireNextTest()
            }

            Button("Reset Onboarding") {
                ButtonSound.shared.play()
                OnboardingController.reset()
                OnboardingController.show()
            }
            #endif

            Divider()

            Button("Quit") {
                ButtonSound.shared.play()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        } label: {
            let moodState = MenuBarMood.shared
            Image(nsImage: MenuBarIcon.create(
                mood: moodState.mood,
                animationFrame: moodState.animationFrame
            ))
        }
    }
}

/// App delegate handles hotkey registration at launch.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        let isLoggedIn = ClaudeService.shared.isLoggedIn
        let hasAccessibility = PermissionsChecker.shared.isAccessibilityGranted()
        logger.info("App launched — loggedIn: \(isLoggedIn), accessibility: \(hasAccessibility)")

        // Show onboarding on first launch
        let onboardingCompleted = OnboardingController.isCompleted
        logger.info("Launch check — onboardingCompleted: \(onboardingCompleted)")
        if !onboardingCompleted {
            logger.info("Showing onboarding on first launch")
            OnboardingController.show()
        } else {
            logger.info("Skipping onboarding — already completed")
        }

        // Register global hotkey: ⌥ + Space
        PromptPanelController.shared.register()

        // Request notification authorization
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                logger.error("Notification auth error: \(error.localizedDescription)")
            } else {
                logger.info("Notification auth granted: \(granted)")
            }
        }

        // Start the scheduler
        ScheduleStore.shared.start()

        // Start clipboard monitoring for the Tools tab
        ClipboardMonitor.shared.start()
    }

    func applicationWillTerminate(_: Notification) {
        logger.info("App terminating")
        ClipboardMonitor.shared.stop()
        ScheduleStore.shared.stop()
        PromptPanelController.shared.unregister()
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
