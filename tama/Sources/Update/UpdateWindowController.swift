import AppKit
import SwiftUI

@MainActor
enum UpdateWindowController {
    private static var panel: NSPanel?

    static func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = UpdateView()
        panel = DropdownPanelController.show(content: view)
    }

    static func dismiss() {
        DropdownPanelController.dismiss(&panel)
    }
}
