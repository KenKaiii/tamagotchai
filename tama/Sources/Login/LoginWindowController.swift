import AppKit
import SwiftUI

@MainActor
enum LoginWindowController {
    private static var panel: NSPanel?

    static func show(onLoginStateChanged: @escaping (Bool) -> Void) {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LoginView(onLoginStateChanged: onLoginStateChanged)
        panel = DropdownPanelController.show(content: view)
    }

    static func dismiss() {
        DropdownPanelController.dismiss(&panel)
    }
}
