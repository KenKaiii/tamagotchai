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

    /// Timestamp of the last time the cursor was shown/moved to a new target.
    /// Used by `awaitPacingIfNeeded()` to prevent the cursor from racing ahead
    /// of TTS narration when an agent turn contains multiple rapid `point`
    /// calls. Tool calls in a single stream execute ~1ms each; TTS plays in
    /// real time, so without pacing the cursor lands on step 3 while the
    /// voice is still describing step 1.
    private static var lastShowAt: Date = .distantPast

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

    /// Minimum time between consecutive point calls. Tuned to roughly the
    /// duration of a short TTS-spoken sentence ("click the File menu") so
    /// the cursor stays visually in sync with the agent's narration. Can
    /// be overridden by a longer explicit `hold_seconds` on the previous call.
    nonisolated static let minPointDwell: TimeInterval = 3.0

    // MARK: - Public API

    /// Show the virtual cursor at a normalized point on the given screen.
    /// If the cursor is already visible (on any display), it animates from its
    /// current position; otherwise it fades in at the target.
    ///
    /// `upcoming` is an optional array of normalized (x, y) coords for later
    /// steps in a walkthrough. Rendered as faint orange dots so the user can
    /// see the full path at a glance. Pass `[]` for single-target pointing.
    static func show(
        atNormalizedX x: Double,
        y: Double,
        on screen: NSScreen,
        label: String? = nil,
        pulse: Bool = true,
        holdSeconds: TimeInterval = defaultHoldSeconds,
        upcoming: [(x: Double, y: Double)] = []
    ) {
        installScreenObserverIfNeeded()

        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        let clampedHold = min(max(holdSeconds, minHoldSeconds), maxHoldSeconds)
        let target = appKitPoint(forNormalizedX: clampedX, y: clampedY, inFrame: screen.frame)
        let displayID = displayID(for: screen)

        // Convert upcoming normalized coords to screen-space points the panel
        // can render directly. Clamp each to [0, 1] defensively.
        let upcomingPoints: [CGPoint] = upcoming.map { step in
            let cx = min(max(step.x, 0.0), 1.0)
            let cy = min(max(step.y, 0.0), 1.0)
            return appKitPoint(forNormalizedX: cx, y: cy, inFrame: screen.frame)
        }

        let logSummary = String(
            format: "Show virtual cursor at (%.3f, %.3f) on display %u (+%d upcoming)",
            clampedX, clampedY, displayID, upcomingPoints.count
        )
        logger.info("\(logSummary, privacy: .public)")

        // Cancel any pending hide — a fresh show/move means the agent is actively pointing.
        pendingHide?.cancel()
        pendingHide = nil

        let panel = ensurePanel(for: screen, displayID: displayID)

        if let active = activeDisplayID, active != displayID {
            // Moving to a new display — hide cursor on the old one.
            panels[active]?.fadeOutCursor(duration: 0.15)
        }

        if activeDisplayID == displayID, panel.isCursorVisible {
            panel.moveCursor(
                to: target,
                duration: defaultMoveDuration,
                label: label,
                pulse: pulse,
                upcoming: upcomingPoints
            )
        } else {
            panel.showCursor(at: target, label: label, pulse: pulse, upcoming: upcomingPoints)
        }

        activeDisplayID = displayID
        lastShowAt = Date()
        // Start the hold timer AFTER the cursor has arrived and fully faded
        // in. Otherwise the first ~0.8s of the hold is eaten by the move
        // animation and the user barely sees the cursor at its target.
        scheduleHide(after: arrivalSettleTime + clampedHold)
    }

    /// Returns how long the caller should wait *before* calling `show` to
    /// respect the minimum dwell between consecutive point gestures. Zero
    /// when enough time has passed (or when the cursor is being shown for
    /// the first time). The `PointTool` awaits this duration so back-to-back
    /// point calls within a single agent turn pace themselves to roughly
    /// match TTS narration speed instead of racing ahead of the voice.
    static func pacingDelay() -> TimeInterval {
        let elapsed = Date().timeIntervalSince(lastShowAt)
        let remaining = minPointDwell - elapsed
        return max(0, remaining)
    }

    /// Hide the virtual cursor after `delay` seconds.
    static func hide(after delay: TimeInterval = 0) {
        scheduleHide(after: max(0, delay))
    }

    /// Trigger a pulse at the current cursor position without moving it.
    /// Used by the `emphasize` tool when the agent wants to draw attention
    /// to the thing it's already pointing at (e.g. "click this one"). Also
    /// fires the haptic tick on supported trackpads. No-op when no cursor
    /// is currently visible.
    ///
    /// Returns `true` if a pulse actually fired (cursor was visible on an
    /// active display), `false` otherwise — lets the tool give the agent
    /// feedback that there was nothing to emphasize.
    @discardableResult
    static func emphasize() -> Bool {
        guard let activeID = activeDisplayID,
              let panel = panels[activeID],
              panel.isCursorVisible
        else {
            return false
        }
        panel.pulseAtCurrentPosition()
        return true
    }

    /// Hide immediately, cancelling any pending animations. Safe to call when
    /// nothing is visible.
    static func hideImmediately() {
        pendingHide?.cancel()
        pendingHide = nil
        for panel in panels.values {
            panel.fadeOutCursor(duration: 0.15)
            // Tear down every tutor overlay too so nothing lingers past a
            // hide. Each overlay has its own pending-hide work; clearing
            // now avoids a zombie highlight/arrow outliving the cursor.
            panel.hideAllOverlays()
        }
        activeDisplayID = nil
        // Clear the pacing clock — once the cursor is gone, any TTS that
        // paired with it has already concluded, so the next `show` has
        // nothing to pace against.
        lastShowAt = .distantPast
    }

    // MARK: - Tutor overlay entrypoints

    /// Show a dashed rectangle or circle highlight on `screen`. All fractions
    /// use normalized top-left-origin coords matching the `point` tool so the
    /// agent can reuse its screenshot arithmetic.
    static func showHighlight(
        shape: VirtualCursorPanel.HighlightShape,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        on screen: NSScreen,
        label: String?,
        holdSeconds: TimeInterval
    ) {
        installScreenObserverIfNeeded()
        let displayID = displayID(for: screen)
        let panel = ensurePanel(for: screen, displayID: displayID)

        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        let clampedW = min(max(width, 0.0001), 1.0)
        let clampedH = min(max(height, 0.0001), 1.0)

        // Compute the AppKit-space rect (origin at bottom-left, y grows up).
        let frame = screen.frame
        let topLeft = appKitPoint(forNormalizedX: clampedX, y: clampedY, inFrame: frame)
        let pxWidth = clampedW * frame.width
        let pxHeight = clampedH * frame.height
        let rect = CGRect(
            x: topLeft.x,
            y: topLeft.y - pxHeight,
            width: pxWidth,
            height: pxHeight
        )

        logger.info(
            """
            Show highlight \(shape.rawValue, privacy: .public) at \
            (\(clampedX), \(clampedY)) size \(clampedW)x\(clampedH) on display \(displayID)
            """
        )
        panel.showHighlight(
            shape: shape,
            globalFrame: rect,
            label: label,
            holdSeconds: holdSeconds
        )
    }

    /// Draw a curved arrow from (x1, y1) to (x2, y2) using normalized coords.
    static func showArrow(
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double,
        on screen: NSScreen,
        label: String?,
        style: VirtualCursorPanel.ArrowStyle,
        holdSeconds: TimeInterval
    ) {
        installScreenObserverIfNeeded()
        let displayID = displayID(for: screen)
        let panel = ensurePanel(for: screen, displayID: displayID)

        let start = appKitPoint(
            forNormalizedX: min(max(x1, 0.0), 1.0),
            y: min(max(y1, 0.0), 1.0),
            inFrame: screen.frame
        )
        let end = appKitPoint(
            forNormalizedX: min(max(x2, 0.0), 1.0),
            y: min(max(y2, 0.0), 1.0),
            inFrame: screen.frame
        )
        logger.info(
            "Show arrow from (\(x1), \(y1)) to (\(x2), \(y2)) on display \(displayID)"
        )
        panel.showArrow(
            from: start,
            to: end,
            label: label,
            style: style,
            holdSeconds: holdSeconds
        )
    }

    /// Show a depleting ring countdown at the given normalized coords (or
    /// screen centre when `x`/`y` are nil).
    static func showCountdown(
        seconds: TimeInterval,
        x: Double?,
        y: Double?,
        on screen: NSScreen,
        label: String?
    ) {
        installScreenObserverIfNeeded()
        let displayID = displayID(for: screen)
        let panel = ensurePanel(for: screen, displayID: displayID)

        let nx = min(max(x ?? 0.5, 0.0), 1.0)
        let ny = min(max(y ?? 0.5, 0.0), 1.0)
        let point = appKitPoint(forNormalizedX: nx, y: ny, inFrame: screen.frame)
        let clamped = min(max(seconds, 0.5), 60.0)
        logger.info("Show countdown \(clamped)s at (\(nx), \(ny)) on display \(displayID)")
        panel.showCountdown(seconds: clamped, at: point, label: label)
    }

    /// Show a pulsing directional chevron pinned to the given edge.
    static func showScrollHint(
        direction: VirtualCursorPanel.ScrollDirection,
        on screen: NSScreen,
        label: String?,
        holdSeconds: TimeInterval
    ) {
        installScreenObserverIfNeeded()
        let displayID = displayID(for: screen)
        let panel = ensurePanel(for: screen, displayID: displayID)
        logger.info("Show scroll hint \(direction.rawValue, privacy: .public) on display \(displayID)")
        panel.showScrollHint(direction: direction, label: label, holdSeconds: holdSeconds)
    }

    /// Show a centred keycap HUD for a keyboard shortcut.
    static func showShortcut(
        keys: [VirtualCursorPanel.ShortcutKey],
        label: String?,
        on screen: NSScreen,
        holdSeconds: TimeInterval
    ) {
        installScreenObserverIfNeeded()
        let displayID = displayID(for: screen)
        let panel = ensurePanel(for: screen, displayID: displayID)
        logger.info(
            """
            Show shortcut HUD (\(keys.count) keys) on display \(displayID)
            """
        )
        panel.showShortcut(keys: keys, label: label, holdSeconds: holdSeconds)
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

    /// Test hook: reset the pacing clock without going through `hide`.
    /// Lets tests exercise back-to-back `show` calls at millisecond-level
    /// timing without hitting the 3s min dwell. Not called by production code.
    static func resetPacingForTesting() {
        lastShowAt = .distantPast
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
