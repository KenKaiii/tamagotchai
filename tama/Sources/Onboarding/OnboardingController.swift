import AppKit
import os
import SwiftUI

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "onboarding"
)

/// NSWindow subclass that can become key even when borderless.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Manages the onboarding window shown on first launch.
@MainActor
enum OnboardingController {
    private static let completedKey = "onboardingCompleted"
    private static var window: NSWindow?
    private static var activationObserver: NSObjectProtocol?

    /// Whether the user has completed onboarding.
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Shows the onboarding wizard as a centered HUD window.
    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView {
            markCompleted()
            dismiss()
        }

        let windowSize = NSSize(width: 420, height: 580)
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(windowSize)

        let win = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Vibrancy background matching app HUD style
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.wantsLayer = true

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        effect.addSubview(hosting.view)

        win.contentView = container
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - windowSize.width / 2
            let y = screenFrame.midY - windowSize.height / 2
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Show dock icon during onboarding so users can find the app,
        // Cmd+Tab to it, and click it in the dock.
        NSApp.setActivationPolicy(.regular)
        setDockIcon()

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
        startActivationObserver()
        logger.info("Onboarding window shown")
    }

    /// Temporarily lowers the window so system dialogs appear on top.
    /// Called before triggering a permission request or opening System Settings.
    static func yieldToSystemUI() {
        window?.level = .normal
    }

    /// Watches for app re-activation to restore floating level.
    private static func startActivationObserver() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let win = window else { return }
                win.level = .floating
                win.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Dismisses the onboarding window and hides the dock icon.
    static func dismiss() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        window?.close()
        window = nil

        // Hide dock icon, back to menu-bar-only mode.
        NSApp.setActivationPolicy(.accessory)

        logger.info("Onboarding window dismissed")
    }

    /// Marks onboarding as completed so it won't show again.
    private static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
        logger.info("Onboarding marked as completed")
    }

    /// Resets onboarding state (for testing).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: completedKey)
        logger.info("Onboarding state reset")
    }

    /// Draws the vector mascot as a crisp dock icon at 1024x1024 pixels.
    private static func setDockIcon() {
        let ptSize: CGFloat = 512
        let pxSize = 1024

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxSize,
            height: pxSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        let scale = CGFloat(pxSize) / ptSize
        ctx.scaleBy(x: scale, y: scale)

        let fullRect = CGRect(origin: .zero, size: CGSize(width: ptSize, height: ptSize))

        // Dark rounded-rect background
        let cornerRadius = ptSize * 0.22
        let bgPath = CGMutablePath()
        bgPath.addRoundedRect(in: fullRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        ctx.addPath(bgPath)
        ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1.0))
        ctx.fillPath()

        // Draw mascot in white, scaled up from 18pt design size
        let mascotDesignSize: CGFloat = 18
        let mascotInset = ptSize * 0.18
        let mascotRect = fullRect.insetBy(dx: mascotInset, dy: mascotInset)

        ctx.saveGState()
        ctx.translateBy(x: mascotRect.origin.x, y: mascotRect.origin.y)
        ctx.scaleBy(x: mascotRect.width / mascotDesignSize, y: mascotRect.height / mascotDesignSize)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        let drawRect = NSRect(origin: .zero, size: NSSize(width: mascotDesignSize, height: mascotDesignSize))
        MenuBarIcon.draw(
            in: drawRect,
            mood: .afternoon,
            animationFrame: false,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        NSGraphicsContext.current = nil
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: ptSize, height: ptSize))
        NSApp.applicationIconImage = image
        logger.info("Dock icon set from vector mascot")
    }
}
