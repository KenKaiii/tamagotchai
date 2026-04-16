import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "virtualcursor"
)

/// Agent-controlled floating "fake" cursor used for tutor-mode guidance.
///
/// The virtual cursor is a click-through overlay that lets the agent visually
/// point at spots on the user's screen ("click here", "this menu"). It never
/// moves or hijacks the user's real cursor — the user keeps full control.
///
/// One `NSPanel` is lazily created per display, keyed by `CGDirectDisplayID`.
/// The controller tracks which display currently owns the visible cursor so
/// back-to-back `move` calls animate from the actual displayed position
/// instead of teleporting.
@MainActor
enum VirtualCursorController {
    // MARK: - State

    /// Panels keyed by display ID (stable across hot-plug / reordering).
    private static var panels: [CGDirectDisplayID: VirtualCursorPanel] = [:]

    /// Display ID of the panel currently showing the cursor, if any.
    private static var activeDisplayID: CGDirectDisplayID?

    /// Pending hide work item. Replaced / cancelled when a new `move` / `show`
    /// comes in while a hide is scheduled.
    private static var pendingHide: DispatchWorkItem?

    /// Whether the screen-parameters observer has been installed. Guarded so
    /// we only install once even if `show` is called before tests.
    private static var observerInstalled = false

    // MARK: - Constants

    // Constants are `nonisolated` so non-MainActor callers (tests, the
    // `PointTool.inputSchema`, etc.) can read them without hopping threads.

    /// Default animation duration for `move`. 600ms feels deliberate but not
    /// sluggish — matches the plan.
    nonisolated static let defaultMoveDuration: TimeInterval = 0.6

    /// Default visible duration *after the cursor arrives* at the target
    /// before it auto-fades. 8s gives the user time to track their eyes to
    /// the cursor, hear the agent's narration, and move their real cursor
    /// there — 3s felt like the cursor flashed and was gone.
    nonisolated static let defaultHoldSeconds: TimeInterval = 8.0

    /// Clamp bounds for the `hold_seconds` arg exposed to the agent.
    nonisolated static let minHoldSeconds: TimeInterval = 0.5
    nonisolated static let maxHoldSeconds: TimeInterval = 60.0

    /// Extra time the user needs after the cursor arrives to actually look at
    /// it. The hold timer starts only after the move animation + fade-in
    /// settles — otherwise a 3s hold on a 0.6s move leaves only ~2s visible.
    private static let arrivalSettleTime: TimeInterval = defaultMoveDuration + 0.2

    // MARK: - Public API

    /// Show the virtual cursor at a normalized point on the given screen.
    /// If the cursor is already visible (on any display), it animates from its
    /// current position; otherwise it fades in at the target.
    static func show(
        atNormalizedX x: Double,
        y: Double,
        on screen: NSScreen,
        label: String? = nil,
        pulse: Bool = true,
        holdSeconds: TimeInterval = defaultHoldSeconds
    ) {
        installScreenObserverIfNeeded()

        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        let clampedHold = min(max(holdSeconds, minHoldSeconds), maxHoldSeconds)
        let target = appKitPoint(forNormalizedX: clampedX, y: clampedY, inFrame: screen.frame)
        let displayID = displayID(for: screen)

        let coordString = String(format: "(%.3f, %.3f)", clampedX, clampedY)
        logger.info("Show virtual cursor at \(coordString) on display \(displayID)")

        // Cancel any pending hide — a fresh show/move means the agent is actively pointing.
        pendingHide?.cancel()
        pendingHide = nil

        let panel = ensurePanel(for: screen, displayID: displayID)

        if let active = activeDisplayID, active != displayID {
            // Moving to a new display — hide cursor on the old one.
            panels[active]?.fadeOutCursor(duration: 0.15)
        }

        if activeDisplayID == displayID, panel.isCursorVisible {
            panel.moveCursor(to: target, duration: defaultMoveDuration, label: label, pulse: pulse)
        } else {
            panel.showCursor(at: target, label: label, pulse: pulse)
        }

        activeDisplayID = displayID
        // Start the hold timer AFTER the cursor has arrived and fully faded
        // in. Otherwise the first ~0.8s of the hold is eaten by the move
        // animation and the user barely sees the cursor at its target.
        scheduleHide(after: arrivalSettleTime + clampedHold)
    }

    /// Hide the virtual cursor after `delay` seconds.
    static func hide(after delay: TimeInterval = 0) {
        scheduleHide(after: max(0, delay))
    }

    /// Hide immediately, cancelling any pending animations. Safe to call when
    /// nothing is visible.
    static func hideImmediately() {
        pendingHide?.cancel()
        pendingHide = nil
        for panel in panels.values {
            panel.fadeOutCursor(duration: 0.15)
        }
        activeDisplayID = nil
    }

    // MARK: - Coordinate Conversion

    /// Convert a normalized (0-1, top-left origin) coordinate pair to an
    /// AppKit point in global screen coordinates for a screen with the given
    /// frame.
    ///
    /// AppKit's coordinate system has the origin at the *bottom-left* of the
    /// primary display and Y increasing upward, so the Y axis is flipped from
    /// the agent's (top-left origin) view of the screen.
    ///
    /// Works for screens at any offset in the global desktop (including
    /// negative `minX` / `minY` for screens placed left/below the main one),
    /// and for any scale factor since we operate in points.
    /// Marked `nonisolated` — pure math, safe to call from any actor.
    nonisolated static func appKitPoint(
        forNormalizedX x: Double,
        y: Double,
        inFrame frame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: frame.minX + x * frame.width,
            y: frame.maxY - y * frame.height
        )
    }

    /// Convenience wrapper over ``appKitPoint(forNormalizedX:y:inFrame:)`` that
    /// reads `screen.frame`. Unit tests use the rect-based overload directly
    /// since `NSScreen` can't be instantiated with a custom frame.
    static func appKitPoint(
        forNormalizedX x: Double,
        y: Double,
        on screen: NSScreen
    ) -> CGPoint {
        appKitPoint(forNormalizedX: x, y: y, inFrame: screen.frame)
    }

    /// Returns the `NSScreen` for a 0-based display index, or `nil` if the
    /// index is out of range. Index 0 is treated as the main screen.
    static func screen(forIndex index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        guard index >= 0, index < screens.count else { return nil }
        return screens[index]
    }

    /// Number of currently attached screens.
    static var screenCount: Int { NSScreen.screens.count }

    /// Resolve a screen's stable `CGDirectDisplayID`. Falls back to a
    /// synthesized ID derived from the screen's frame hash when the
    /// `NSScreenNumber` device description is unavailable (shouldn't happen
    /// in practice but keeps the controller testable).
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        if let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        // Extremely rare fallback — hash the frame into a 32-bit space.
        var hasher = Hasher()
        hasher.combine(screen.frame.origin.x)
        hasher.combine(screen.frame.origin.y)
        hasher.combine(screen.frame.size.width)
        hasher.combine(screen.frame.size.height)
        return CGDirectDisplayID(UInt32(truncatingIfNeeded: hasher.finalize()))
    }

    // MARK: - Private

    private static func ensurePanel(
        for screen: NSScreen,
        displayID: CGDirectDisplayID
    ) -> VirtualCursorPanel {
        if let existing = panels[displayID] {
            // Keep the panel's frame in sync with the screen — resolution
            // changes don't trigger a new display ID but do change the frame.
            existing.syncFrame(to: screen.frame)
            return existing
        }
        let panel = VirtualCursorPanel(screenFrame: screen.frame)
        panels[displayID] = panel
        logger.info("Created virtual cursor panel for display \(displayID)")
        return panel
    }

    private static func scheduleHide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                hideImmediately()
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func installScreenObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                screenParametersDidChange()
            }
        }
    }

    private static func screenParametersDidChange() {
        let currentIDs = Set(NSScreen.screens.map(displayID(for:)))
        let cachedIDs = Set(panels.keys)
        let removed = cachedIDs.subtracting(currentIDs)
        for id in removed {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
            if activeDisplayID == id {
                activeDisplayID = nil
            }
        }
        if !removed.isEmpty {
            logger.info("Invalidated \(removed.count) virtual cursor panels after screen change")
        }
    }
}
