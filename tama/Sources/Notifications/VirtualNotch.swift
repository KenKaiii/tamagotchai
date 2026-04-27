import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "virtualnotch"
)

/// A persistent black notch shape drawn at the top-center of the main screen.
///
/// On real notched MacBooks this overlays the hardware notch perfectly — invisible to the
/// user but captured by screen recorders, which otherwise would show the call wing alone
/// hovering at the top of the menu bar. On non-notch displays this also gives the app a
/// notch-like aesthetic that matches the call wings.
///
/// Hides automatically while a transient notch overlay (notification / activity indicator)
/// is active, since those already draw their own notch silhouette as part of the animation.
@MainActor
enum VirtualNotch {
    // MARK: - State

    private static var panel: NSPanel?
    private static var shapeLayer: CAShapeLayer?
    private static var isVisible = false
    private static var isHiddenByOverlay = false

    // MARK: - Public API

    /// Show the virtual notch at the top of the main screen.
    static func show() {
        guard !isVisible else { return }
        guard let screen = NSScreen.main else { return }

        logger.info("Showing virtual notch")
        isVisible = true

        let notchSize = screen.exactNotchSize
        let screenFrame = screen.frame

        let originX = screenFrame.midX - notchSize.width / 2
        let originY = screenFrame.maxY - notchSize.height

        let newPanel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: notchSize.width, height: notchSize.height),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .mainMenu + 2
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.appearance = NSAppearance(named: .darkAqua)

        let rootView = FlippedNotchView(
            frame: NSRect(x: 0, y: 0, width: notchSize.width, height: notchSize.height)
        )
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let shape = CAShapeLayer()
        shape.fillColor = NSColor.black.cgColor
        shape.path = NotchShapePath.path(
            in: CGRect(x: 0, y: 0, width: notchSize.width, height: notchSize.height)
        )
        shape.frame = rootView.bounds
        rootView.layer?.addSublayer(shape)

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        panel = newPanel
        shapeLayer = shape

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in reposition() }
        }

        // Hide while overlays are active — they draw their own notch shape.
        NotificationCenter.default.addObserver(
            forName: .notchOverlayActive,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in hideForOverlay() }
        }
        NotificationCenter.default.addObserver(
            forName: .notchOverlayInactive,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in showAfterOverlay() }
        }

        if NotchOverlayTracker.isActive {
            hideForOverlay()
        }
    }

    /// Hide and tear down the virtual notch.
    static func hide() {
        guard isVisible else { return }
        logger.info("Hiding virtual notch")
        isVisible = false
        isHiddenByOverlay = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(self, name: .notchOverlayActive, object: nil)
        NotificationCenter.default.removeObserver(self, name: .notchOverlayInactive, object: nil)

        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
    }

    // MARK: - Overlay coordination

    private static func hideForOverlay() {
        guard isVisible, !isHiddenByOverlay else { return }
        isHiddenByOverlay = true
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    private static func showAfterOverlay() {
        guard isVisible, isHiddenByOverlay else { return }
        isHiddenByOverlay = false
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    // MARK: - Positioning

    private static func reposition() {
        guard isVisible, let panel, let shapeLayer, let screen = NSScreen.main else { return }
        let notchSize = screen.exactNotchSize
        let screenFrame = screen.frame
        let originX = screenFrame.midX - notchSize.width / 2
        let originY = screenFrame.maxY - notchSize.height
        panel.setFrame(
            NSRect(x: originX, y: originY, width: notchSize.width, height: notchSize.height),
            display: true
        )
        shapeLayer.frame = CGRect(x: 0, y: 0, width: notchSize.width, height: notchSize.height)
        shapeLayer.path = NotchShapePath.path(
            in: CGRect(x: 0, y: 0, width: notchSize.width, height: notchSize.height)
        )
    }
}

// MARK: - Flipped View

private final class FlippedNotchView: NSView {
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        return layer
    }
}
