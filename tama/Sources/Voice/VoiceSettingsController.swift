import AppKit
import SwiftUI

@MainActor
enum VoiceSettingsController {
    private static var panel: NSPanel?

    static func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = VoiceSettingsView()
        panel = DropdownPanelController.show(content: view)
    }

    static func dismiss() {
        DropdownPanelController.dismiss(&panel)
    }
}
