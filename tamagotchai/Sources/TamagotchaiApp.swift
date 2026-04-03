import os
import SwiftUI
import UserNotifications

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "app"
)

@main
struct TamagotchaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var isLoggedIn = ClaudeService.shared.isLoggedIn

    var body: some Scene {
        // Menu bar presence — the app lives in the menu bar
        MenuBarExtra {
            Button("Open Tamagotchai") {
                PromptPanelController.shared.toggle()
            }
            .keyboardShortcut(.space, modifiers: [.option])

            Button("Permissions…") {
                PermissionsWindowController.show()
            }

            Button("Voice Settings…") {
                VoiceSettingsController.show()
            }

            Divider()

            if isLoggedIn {
                Button("Claude Account…") {
                    LoginWindowController.show(isLoggedIn: true) { isLoggedIn = $0 }
                }
            } else {
                Button("Login to Claude…") {
                    LoginWindowController.show(isLoggedIn: false) { isLoggedIn = $0 }
                }
            }

            #if DEBUG
            Divider()

            Button("Test Notification") {
                NotchNotificationPresenter.showReminder(
                    name: "Test Reminder",
                    message: "This is a test notification to preview the toast style."
                )
            }
            #endif

            Divider()

            Button("Quit") {
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
    }

    func applicationWillTerminate(_: Notification) {
        logger.info("App terminating")
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
