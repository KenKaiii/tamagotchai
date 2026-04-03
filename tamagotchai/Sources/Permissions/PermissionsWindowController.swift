import AppKit
import SwiftUI

@MainActor
enum PermissionsWindowController {
    private static var panel: NSPanel?

    static func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        panel = DropdownPanelController.show(content: PermissionsView())
    }

    static func dismiss() {
        DropdownPanelController.dismiss(&panel)
    }
}
