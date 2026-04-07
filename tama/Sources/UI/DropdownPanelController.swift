import AppKit
import SwiftUI

/// An NSPanel subclass that stays visible when it loses key/main status
/// or when the app deactivates (e.g. a system permission dialog appears).
private final class StablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Reusable dropdown panel that appears below the menu bar with a HUD-style vibrancy background.
/// Used by LoginWindowController and PermissionsWindowController.
@MainActor
enum DropdownPanelController {
    private static let cornerRadius: CGFloat = 20

    /// Creates and shows a dropdown panel hosting the given SwiftUI view.
    /// Returns the created NSPanel so the caller can store and dismiss it later.
    @discardableResult
    static func show(content: some View) -> NSPanel {
        let hosting = NSHostingController(rootView: content)
        hosting.view.setFrameSize(hosting.view.fittingSize)

        let windowSize = hosting.view.fittingSize

        let window = StablePanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Vibrancy background matching the chat input style
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.wantsLayer = true

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        effect.addSubview(hosting.view)

        window.contentView = container
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        // Float above other windows so system permission dialogs don't hide us
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false

        // Position directly below the menu bar icon using the mouse location
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main {
            let menuBarBottom = screen.visibleFrame.maxY
            let x = min(
                max(mouseLocation.x - windowSize.width / 2, screen.visibleFrame.minX),
                screen.visibleFrame.maxX - windowSize.width
            )
            let y = menuBarBottom - windowSize.height
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        return window
    }

    /// Dismisses a dropdown panel.
    static func dismiss(_ panel: inout NSPanel?) {
        panel?.close()
        panel = nil
    }
}
