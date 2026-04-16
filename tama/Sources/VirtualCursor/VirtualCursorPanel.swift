import AppKit
import Foundation
import os
import QuartzCore

private let panelLogger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "virtualcursor.panel"
)

/// A borderless, click-through, screen-spanning `NSPanel` that hosts the
/// virtual cursor visual and its pulse ring. One panel per display.
///
/// The panel sits at `.screenSaver` level with `.fullScreenAuxiliary`
/// collection behaviour so it floats above the menu bar, the dock, and even
/// fullscreen apps. `ignoresMouseEvents = true` is the critical piece that
/// keeps the user's real cursor in control — events pass right through.
@MainActor
final class VirtualCursorPanel: NSPanel {
    // MARK: - Layers

    /// The cursor glyph layer. `position` is the *tip* of the arrow —
    /// we offset the image within the layer's `contents` rect so the
    /// arrow tip lines up with the target point rather than its centre.
    private let cursorLayer: CALayer

    /// White outline layer sitting just behind the cursor for contrast.
    private let outlineLayer: CALayer

    /// Pulse ring layer — a hollow circle that expands and fades when the
    /// agent "clicks" at the target.
    private let pulseLayer: CAShapeLayer

    /// Optional label shown next to the cursor ("File menu" etc.).
    private let labelView: VirtualCursorLabelView

    /// Ghost markers for "upcoming" steps in a walkthrough. Each is a small
    /// translucent dot + connector. Re-created from scratch every `showCursor`
    /// / `moveCursor` call since they're cheap to rebuild and their count
    /// varies call-to-call.
    private var ghostLayers: [CALayer] = []

    // MARK: - Overlay layers (tutor tools)

    /// Dashed region outline drawn by the `highlight` tool. Replaced on each
    /// call; one active highlight per panel.
    private let highlightLayer = CAShapeLayer()
    /// Label pill anchored near the highlight shape's top-right corner.
    private let highlightLabelView = VirtualCursorLabelView()

    /// Filled arrow drawn by the `arrow` tool. Replaced on each call.
    private let arrowLayer = CAShapeLayer()
    /// Label pill anchored at the arrow's midpoint.
    private let arrowLabelView = VirtualCursorLabelView()

    /// Depleting ring drawn by the `countdown` tool. Replaced on each call.
    private let countdownLayer = CAShapeLayer()
    /// Background track behind the depleting ring for contrast.
    private let countdownTrackLayer = CAShapeLayer()
    /// Centred seconds label inside the countdown ring.
    private let countdownTextField = NSTextField(labelWithString: "")
    /// Active countdown timer (drives the whole-second label + haptic ticks).
    private var countdownTimer: Timer?
    /// End time for the active countdown; used by the timer tick.
    private var countdownEndsAt: Date?

    /// Directional chevron drawn by the `scroll_hint` tool.
    private let scrollHintImageView = NSImageView()
    /// Label pill shown alongside the scroll-hint chevron.
    private let scrollHintLabelView = VirtualCursorLabelView()
    /// Pending hide work for the scroll hint so later calls can cancel it.
    private var pendingScrollHintHide: DispatchWorkItem?

    /// Centred HUD drawn by the `show_shortcut` tool.
    private let shortcutHUDView = NSView()
    /// Horizontal stack of keycap subviews inside the HUD.
    private let shortcutKeysStack = NSStackView()
    /// Optional explanatory label below the keycaps.
    private let shortcutLabelField = NSTextField(labelWithString: "")
    /// Background vibrancy for the HUD.
    private let shortcutHUDBackground = NSVisualEffectView()
    /// Pending hide work for the shortcut HUD.
    private var pendingShortcutHide: DispatchWorkItem?

    /// Pending hide work for the highlight so later calls can cancel.
    private var pendingHighlightHide: DispatchWorkItem?
    /// Pending hide work for the arrow so later calls can cancel.
    private var pendingArrowHide: DispatchWorkItem?

    // MARK: - Config

    /// Logical size (in points) of the cursor glyph. Doubled from 32 — at
    /// the smaller size users had trouble spotting the tutor cursor on
    /// modern high-res displays, especially against busy UI.
    private static let cursorSize: CGFloat = 64
    /// Outline padding around the cursor for the white halo. Scaled with
    /// the cursor so the halo stays proportional.
    private static let outlinePadding: CGFloat = 4
    /// Offset from the target to where the cursor tip is drawn. The arrow
    /// tip (top-left of the image) lands *on* the target, so the visible
    /// body extends down-and-right from the point.
    private static let tipOffset = CGPoint(x: 0, y: 0)

    /// Gentle idle oscillation while the cursor is parked at the target so
    /// it reads as "alive", not frozen. Values are chosen to be subtle enough
    /// not to distract from whatever the user is looking at.
    private static let idleBreathScale: CGFloat = 0.97
    private static let idleBreathDuration: TimeInterval = 1.6

    /// Micro-bounce when the cursor lands — gives a clear "arrived" beat.
    private static let arrivalBumpScale: CGFloat = 1.14
    private static let arrivalBumpDuration: TimeInterval = 0.32

    /// Visual config for the "upcoming steps" ghost markers.
    private static let ghostRadius: CGFloat = 6
    /// Opacity falls off for later steps so the user can tell the order.
    private static let ghostMaxOpacity: Float = 0.55
    private static let ghostMinOpacity: Float = 0.22

    /// True when the user has "Reduce motion" enabled in accessibility
    /// settings. We drop spring physics, the idle breath, and the arrival
    /// bump in that case — animations become near-instant, which is the
    /// Apple-recommended behaviour.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private(set) var isCursorVisible = false

    // MARK: - Init

    init(screenFrame: NSRect) {
        cursorLayer = CALayer()
        outlineLayer = CALayer()
        pulseLayer = CAShapeLayer()
        labelView = VirtualCursorLabelView()

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        isReleasedWhenClosed = false
        // Disable the system fade-in/out on orderFront / orderOut. We drive
        // show/hide through custom Core Animation fades on the cursor/outline
        // layers — the default `.utilityWindow`-style window animation would
        // collide with those and has been reported to crash on rapid show/hide
        // cycles while CA transactions are in flight.
        animationBehavior = .none

        let root = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        root.wantsLayer = true
        root.layer = CALayer()
        root.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = root

        // Overlays go underneath the cursor so a visible cursor always
        // reads as the foreground focus; the shortcut HUD and scroll-hint
        // chevron are separate subviews layered above everything else.
        configureOverlayLayers()
        configureLayers()
        root.addSubview(highlightLabelView)
        root.addSubview(arrowLabelView)
        root.addSubview(labelView)
        root.addSubview(scrollHintImageView)
        root.addSubview(scrollHintLabelView)
        root.addSubview(shortcutHUDView)
    }

    // MARK: - Overlay visibility (inspection / testing)

    /// True when the dashed highlight overlay is currently visible.
    private(set) var isHighlightVisible = false
    /// True when the arrow overlay is currently visible.
    private(set) var isArrowVisible = false
    /// True when the countdown ring is currently running.
    private(set) var isCountdownVisible = false
    /// True when the scroll-hint chevron is visible on an edge.
    private(set) var isScrollHintVisible = false
    /// True when the keyboard shortcut HUD is visible.
    private(set) var isShortcutHUDVisible = false

    // MARK: - Public

    /// Move the panel to cover a new screen frame (handles resolution changes).
    func syncFrame(to screenFrame: NSRect) {
        guard frame != screenFrame else { return }
        setFrame(screenFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: screenFrame.size)
    }

    /// Fade the cursor in at `point` (in global screen coordinates). If a
    /// pulse is requested, schedules the ripple after the fade-in. `upcoming`
    /// is an optional list of later step targets shown as faint ghost dots
    /// so the user can see the whole path at a glance.
    func showCursor(at point: CGPoint, label: String?, pulse: Bool, upcoming: [CGPoint] = []) {
        orderFrontRegardless()

        let local = toLocal(point)
        let showDiag = "showCursor target=\(local.debugDescription) " +
            "panelFrame=\(frame.debugDescription) " +
            "screen=\(screen?.localizedName ?? "nil") " +
            "isVisible=\(isVisible) alphaValue=\(alphaValue) " +
            "cursorOp=\(cursorLayer.opacity) outlineOp=\(outlineLayer.opacity)"
        panelLogger.info("\(showDiag, privacy: .public)")
        // Commit the cursor position without animating the move — only the
        // opacity animates on first show.
        // Remove any stale animations before setting model-layer state.
        // `move`, `fadeOut`, and `fadeIn` are all left on the layer with
        // `isRemovedOnCompletion=false` + `fillMode=.forwards`, meaning they
        // stay pinning the presentation layer at their final value until
        // explicitly removed. A leftover `move` from a previous session
        // pins the presentation position at the OLD target, so setting
        // `cursorLayer.position = local` only updates the model layer —
        // the user sees the cursor materialise at the stale position while
        // the label pill (a separate NSView) correctly lands at `local`.
        // Clearing all three keys guarantees a clean slate.
        cursorLayer.removeAnimation(forKey: "move")
        outlineLayer.removeAnimation(forKey: "move")
        pulseLayer.removeAnimation(forKey: "move")
        cursorLayer.removeAnimation(forKey: "fadeOut")
        outlineLayer.removeAnimation(forKey: "fadeOut")
        cursorLayer.removeAnimation(forKey: "fadeIn")
        outlineLayer.removeAnimation(forKey: "fadeIn")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = local
        outlineLayer.position = local
        pulseLayer.position = local
        CATransaction.commit()

        updateGhosts(upcoming: upcoming, fromLocal: local)
        updateLabel(label, at: local)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.reduceMotion ? 0.05 : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        cursorLayer.opacity = 1
        outlineLayer.opacity = 1
        cursorLayer.add(fade, forKey: "fadeIn")
        outlineLayer.add(fade, forKey: "fadeIn")

        isCursorVisible = true

        // Arrival bump + idle breathing kick in after the fade-in — makes
        // the cursor feel like it actually "landed" and then settles into
        // a subtle rhythm instead of looking frozen.
        let settleDelay = Self.reduceMotion ? 0.05 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isCursorVisible else { return }
                self.playArrivalBump()
                self.startIdleBreath()
                if pulse {
                    self.pulseAtCurrentPosition()
                }
            }
        }
    }

    /// Animate the cursor from its current displayed position to `point`.
    /// Uses spring physics for a natural, weighted motion (matches how the
    /// existing `NotchActivityIndicator` animates). Falls back to a quick
    /// linear snap when the user has "Reduce motion" enabled.
    func moveCursor(
        to point: CGPoint,
        duration: TimeInterval,
        label: String?,
        pulse: Bool,
        upcoming: [CGPoint] = []
    ) {
        // Re-assert front order on every move. When the user switches to a
        // different app (especially a fullscreen one like a browser), the
        // panel can get shuffled below the active window even at .screenSaver
        // level — `orderFrontRegardless` on every move guarantees the cursor
        // stays visible, matching the behaviour of other floating overlays
        // (Loop's radial menu, Maccy's picker) that do the same.
        orderFrontRegardless()

        let local = toLocal(point)
        let current = cursorLayer.presentation()?.position ?? cursorLayer.position

        // Cancel any in-flight move / idle / bump / stale fade so the next
        // motion starts from the actual displayed position and doesn't fight
        // other animations. The fade cleanup is critical: stale fadeOut
        // animations (with isRemovedOnCompletion=false + fillMode=forwards)
        // can otherwise pin the presentation-layer opacity at 0 even after
        // we reset the model layer, leaving the cursor invisible during
        // subsequent moves while only the label shows.
        cursorLayer.removeAnimation(forKey: "move")
        outlineLayer.removeAnimation(forKey: "move")
        pulseLayer.removeAnimation(forKey: "move")
        cursorLayer.removeAnimation(forKey: "fadeOut")
        outlineLayer.removeAnimation(forKey: "fadeOut")
        cursorLayer.removeAnimation(forKey: "fadeIn")
        outlineLayer.removeAnimation(forKey: "fadeIn")
        stopIdleBreath()

        // Defensive: ensure the cursor is actually visible. `moveCursor` is
        // only supposed to be called when the cursor is already up, but
        // state can drift (scheduleHide firing mid-barrier-wait, lingering
        // fadeOut animations, etc.) — so force opacity back to 1 and, if
        // needed, re-run a quick fade-in. Otherwise the user sees the label
        // pill but no cursor dot.
        cursorLayer.opacity = 1
        outlineLayer.opacity = 1
        if !isCursorVisible {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = Self.reduceMotion ? 0.05 : 0.15
            fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cursorLayer.add(fadeIn, forKey: "fadeIn")
            outlineLayer.add(fadeIn, forKey: "fadeIn")
            isCursorVisible = true
        }

        let moveDiag = String(
            format: "moveCursor target=(%.1f, %.1f) from=(%.1f, %.1f) " +
                "panelFrame=(%.0f, %.0f, %.0f×%.0f) screen=%@",
            local.x, local.y,
            current.x, current.y,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            screen?.localizedName ?? "nil"
        )
        panelLogger.info("\(moveDiag, privacy: .public)")

        // Commit the model-layer position FIRST inside a transaction with
        // disabled implicit actions so nothing (pending animations on other
        // keys, spring overshoots, etc.) can make the model layer's position
        // drift from `local`. Then we add the explicit move animation on top
        // — that only affects the presentation layer's trajectory, never
        // the model layer.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = local
        outlineLayer.position = local
        pulseLayer.position = local
        CATransaction.commit()

        let effectiveDuration: TimeInterval
        for layer in [cursorLayer, outlineLayer, pulseLayer] {
            if Self.reduceMotion {
                let anim = CABasicAnimation(keyPath: "position")
                anim.fromValue = NSValue(point: current)
                anim.toValue = NSValue(point: local)
                anim.duration = 0.08
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "move")
            } else {
                let spring = CASpringAnimation(keyPath: "position")
                spring.fromValue = NSValue(point: current)
                spring.toValue = NSValue(point: local)
                spring.damping = 16
                spring.stiffness = 170
                spring.mass = 1.0
                spring.initialVelocity = 0
                // `settlingDuration` gives us the spring's own natural time;
                // use that so all three layers land together regardless of
                // the `duration` caller passed.
                spring.duration = spring.settlingDuration
                spring.fillMode = .forwards
                spring.isRemovedOnCompletion = false
                layer.add(spring, forKey: "move")
            }
        }
        effectiveDuration = Self.reduceMotion ? 0.08 : duration

        updateGhosts(upcoming: upcoming, fromLocal: local)
        updateLabel(label, at: local, animateDuration: effectiveDuration)

        // Arrival bump + resume idle breath after the move settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isCursorVisible else { return }
                self.playArrivalBump()
                self.startIdleBreath()
                if pulse {
                    self.pulseAtCurrentPosition()
                }
            }
        }
    }

    // MARK: - Arrival Bump & Idle Breath

    /// One-shot scale pulse when the cursor arrives at a target. Done via
    /// `transform.scale` as an additive animation so it layers cleanly on
    /// top of whatever idle breathing animation is running.
    private func playArrivalBump() {
        guard !Self.reduceMotion else { return }
        let bump = CAKeyframeAnimation(keyPath: "transform.scale")
        bump.values = [1.0, Self.arrivalBumpScale, 1.0]
        bump.keyTimes = [0, 0.45, 1]
        bump.duration = Self.arrivalBumpDuration
        bump.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        bump.isAdditive = true
        bump.isRemovedOnCompletion = true
        // Bump the outlined halo slightly ahead so it reads as the "shockwave".
        cursorLayer.add(bump, forKey: "arrivalBump")
        outlineLayer.add(bump, forKey: "arrivalBump")
    }

    /// Starts a subtle repeating scale oscillation so a parked cursor
    /// doesn't read as frozen. It's easy to miss consciously but makes
    /// the cursor feel present.
    private func startIdleBreath() {
        guard !Self.reduceMotion else { return }
        let breath = CABasicAnimation(keyPath: "transform.scale")
        breath.fromValue = 1.0
        breath.toValue = Self.idleBreathScale
        breath.duration = Self.idleBreathDuration
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cursorLayer.add(breath, forKey: "idleBreath")
        outlineLayer.add(breath, forKey: "idleBreath")
    }

    private func stopIdleBreath() {
        cursorLayer.removeAnimation(forKey: "idleBreath")
        outlineLayer.removeAnimation(forKey: "idleBreath")
    }

    // MARK: - Upcoming Step Ghosts

    /// Rebuilds the ghost-dot markers for `upcoming` steps. Each dot is a
    /// small translucent orange circle; opacity decreases linearly with
    /// distance along the path so the order is visually clear.
    ///
    /// `upcoming` points are in the panel's local coordinate space. Note
    /// that these are UPCOMING targets (haven't happened yet) — we don't
    /// render the current target as a ghost because the bright cursor is
    /// already there.
    private func updateGhosts(upcoming: [CGPoint], fromLocal current: CGPoint) {
        clearGhosts()
        guard !upcoming.isEmpty, let rootLayer = contentView?.layer else { return }

        // Convert global-screen upcoming points to local.
        let localUpcoming = upcoming.map(toLocal)

        // Fade each ghost's opacity from max (first upcoming) to min (last
        // upcoming) so the sequence reads as a descending chain.
        let count = Double(localUpcoming.count)
        for (index, ghostPoint) in localUpcoming.enumerated() {
            let progress: Double = count > 1 ? Double(index) / (count - 1) : 0
            let opacity = Float(Double(Self.ghostMaxOpacity)
                + (Double(Self.ghostMinOpacity) - Double(Self.ghostMaxOpacity)) * progress)

            let ghost = CAShapeLayer()
            ghost.path = CGPath(
                ellipseIn: CGRect(
                    x: -Self.ghostRadius,
                    y: -Self.ghostRadius,
                    width: Self.ghostRadius * 2,
                    height: Self.ghostRadius * 2
                ),
                transform: nil
            )
            ghost.fillColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
            ghost.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
            ghost.lineWidth = 1
            ghost.position = ghostPoint
            ghost.opacity = 0
            rootLayer.addSublayer(ghost)

            // Fade in with a short stagger so ghosts appear to "stream out"
            // from the cursor, giving a sense of direction.
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = opacity
            fadeIn.beginTime = CACurrentMediaTime() + Double(index) * 0.06
            fadeIn.duration = Self.reduceMotion ? 0.05 : 0.25
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            ghost.add(fadeIn, forKey: "ghostFadeIn")
            ghost.opacity = opacity

            ghostLayers.append(ghost)
        }

        // Silence the compiler's unused-parameter hint; `current` is retained
        // in the API for future line-connector rendering between current
        // target and the first ghost, which we may add later.
        _ = current
    }

    private func clearGhosts() {
        for layer in ghostLayers {
            layer.removeFromSuperlayer()
        }
        ghostLayers.removeAll()
    }

    /// Fade the cursor out over `duration`. Does not close the panel.
    func fadeOutCursor(duration: TimeInterval) {
        guard isCursorVisible else { return }
        isCursorVisible = false
        stopIdleBreath()
        fadeOutGhosts(duration: duration)

        let effectiveDuration = Self.reduceMotion ? 0.05 : duration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = effectiveDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        cursorLayer.opacity = 0
        outlineLayer.opacity = 0
        cursorLayer.add(fade, forKey: "fadeOut")
        outlineLayer.add(fade, forKey: "fadeOut")

        labelView.fadeOut(duration: effectiveDuration)
    }

    /// Fades the upcoming-step ghosts out alongside the main cursor fade.
    /// Ghost layers are removed from the superlayer once their fade completes.
    private func fadeOutGhosts(duration: TimeInterval) {
        let effective = Self.reduceMotion ? 0.05 : duration
        for layer in ghostLayers {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = effective
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.opacity = 0
            layer.add(fade, forKey: "ghostFadeOut")
        }
        // Remove layers from the superlayer after the fade — we'll rebuild
        // on the next show/move anyway.
        let layersToRemove = ghostLayers
        ghostLayers.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + effective + 0.05) {
            for layer in layersToRemove {
                layer.removeFromSuperlayer()
            }
        }
    }

    /// Trigger a ripple at the cursor's current displayed position. Also
    /// fires a subtle trackpad-tick haptic on supported hardware (Force
    /// Touch trackpads) so the user feels the emphasis as well as sees it.
    /// `.alignment` is the lightest system feedback — same one macOS uses
    /// when windows snap to edges. No-op silently on hardware without haptics.
    func pulseAtCurrentPosition() {
        guard isCursorVisible else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        let center = cursorLayer.presentation()?.position ?? cursorLayer.position
        pulseLayer.position = center

        let startRadius: CGFloat = 8
        let endRadius: CGFloat = 32
        let startPath = CGPath(
            ellipseIn: CGRect(x: -startRadius, y: -startRadius, width: startRadius * 2, height: startRadius * 2),
            transform: nil
        )
        let endPath = CGPath(
            ellipseIn: CGRect(x: -endRadius, y: -endRadius, width: endRadius * 2, height: endRadius * 2),
            transform: nil
        )

        let expand = CABasicAnimation(keyPath: "path")
        expand.fromValue = startPath
        expand.toValue = endPath
        expand.duration = 0.6
        expand.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0.0
        fade.duration = 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [expand, fade]
        group.duration = 0.6
        group.fillMode = .forwards
        group.isRemovedOnCompletion = true

        pulseLayer.path = startPath
        pulseLayer.opacity = 0
        pulseLayer.add(group, forKey: "pulse")
    }

    // MARK: - Highlight overlay

    /// The shape family the `highlight` tool can draw. Rectangles have
    /// independent width/height; circles take `width` as diameter.
    enum HighlightShape: String { case rectangle, circle }

    /// Show a dashed orange outline around the region given in global screen
    /// coordinates. Replaces any prior highlight on this panel.
    func showHighlight(
        shape: HighlightShape,
        globalFrame: CGRect,
        label: String?,
        holdSeconds: TimeInterval
    ) {
        orderFrontRegardless()
        pendingHighlightHide?.cancel()
        pendingHighlightHide = nil

        let local = toLocalRect(globalFrame)
        let path = switch shape {
        case .rectangle:
            CGPath(
                roundedRect: local,
                cornerWidth: 12,
                cornerHeight: 12,
                transform: nil
            )
        case .circle:
            CGPath(ellipseIn: local, transform: nil)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.path = path
        highlightLayer.opacity = 1
        CATransaction.commit()

        // Marching-ants style dashed stroke. The phase animation conveys
        // "selection / focus" instead of a static decorative shape.
        let marching = CABasicAnimation(keyPath: "lineDashPhase")
        marching.fromValue = 0
        marching.toValue = -12 // one period of the dash pattern [8, 4]
        marching.duration = 0.6
        marching.repeatCount = .infinity
        highlightLayer.add(marching, forKey: "dashMarch")

        fadeLayerIn(highlightLayer, duration: Self.reduceMotion ? 0.05 : 0.25)
        isHighlightVisible = true

        updateHighlightLabel(label, shapeFrame: local)

        let hold = min(max(holdSeconds, 0.5), 120.0)
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hideHighlight()
            }
        }
        pendingHighlightHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: hide)
    }

    /// Fade the highlight overlay out and clear its label.
    func hideHighlight() {
        pendingHighlightHide?.cancel()
        pendingHighlightHide = nil
        guard isHighlightVisible else { return }
        isHighlightVisible = false
        fadeLayerOut(highlightLayer, duration: Self.reduceMotion ? 0.05 : 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.highlightLayer.removeAnimation(forKey: "dashMarch")
                self?.highlightLayer.path = nil
            }
        }
        highlightLabelView.fadeOut(duration: 0.15)
    }

    private func updateHighlightLabel(_ text: String?, shapeFrame: CGRect) {
        guard let text, !text.isEmpty else {
            highlightLabelView.fadeOut(duration: 0.1)
            return
        }
        highlightLabelView.setText(text)

        let canvas = contentView?.bounds.size ?? frame.size
        let pillWidth = highlightLabelView.frame.width
        let pillHeight = highlightLabelView.frame.height
        let margin: CGFloat = 12

        // Anchor outside the top-right of the shape. Panel coords have y
        // increasing upward, so "top" of the shape in screen terms is the
        // rect's max-y in local coords. Flip to inside-top-right if the pill
        // would clip the right edge.
        var x = shapeFrame.maxX - pillWidth
        if x + pillWidth + margin > canvas.width {
            x = canvas.width - pillWidth - margin
        }
        x = max(margin, x)
        var y = shapeFrame.maxY + 6
        if y + pillHeight > canvas.height - margin {
            y = shapeFrame.maxY - pillHeight - 6
        }
        y = max(margin, y)

        highlightLabelView.setFrameOrigin(NSPoint(x: x, y: y))
        highlightLabelView.alphaValue = 1
    }

    // MARK: - Arrow overlay

    /// Show a filled orange arrow from `start` to `end` (both global screen
    /// coords). Replaces any prior arrow.
    func showArrow(
        from start: CGPoint,
        to end: CGPoint,
        label: String?,
        style: ArrowStyle,
        holdSeconds: TimeInterval
    ) {
        orderFrontRegardless()
        pendingArrowHide?.cancel()
        pendingArrowHide = nil

        let localStart = toLocal(start)
        let localEnd = toLocal(end)

        let path = CGPath.tamaArrow(
            from: localStart,
            to: localEnd,
            tailWidth: 6,
            headWidth: 16,
            headLength: 22
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrowLayer.path = path
        switch style {
        case .solid:
            arrowLayer.lineDashPattern = nil
        case .dashed:
            arrowLayer.lineDashPattern = [6, 4]
        }
        arrowLayer.opacity = 1
        CATransaction.commit()

        // "Draw in" the arrow by animating strokeEnd 0 → 1; the fill catches
        // up in tandem via a short opacity ramp.
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = Self.reduceMotion ? 0.05 : 0.45
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        draw.fillMode = .forwards
        draw.isRemovedOnCompletion = false
        arrowLayer.strokeEnd = 1
        arrowLayer.add(draw, forKey: "drawIn")
        fadeLayerIn(arrowLayer, duration: Self.reduceMotion ? 0.05 : 0.2)
        isArrowVisible = true

        updateArrowLabel(label, from: localStart, to: localEnd)

        let hold = min(max(holdSeconds, 0.5), 120.0)
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hideArrow()
            }
        }
        pendingArrowHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: hide)
    }

    /// Arrow line style — matches the `ArrowTool` schema enum.
    enum ArrowStyle: String { case solid, dashed }

    /// Fade the arrow overlay out.
    func hideArrow() {
        pendingArrowHide?.cancel()
        pendingArrowHide = nil
        guard isArrowVisible else { return }
        isArrowVisible = false
        fadeLayerOut(arrowLayer, duration: Self.reduceMotion ? 0.05 : 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.arrowLayer.path = nil
                self?.arrowLayer.removeAllAnimations()
            }
        }
        arrowLabelView.fadeOut(duration: 0.15)
    }

    private func updateArrowLabel(_ text: String?, from start: CGPoint, to end: CGPoint) {
        guard let text, !text.isEmpty else {
            arrowLabelView.fadeOut(duration: 0.1)
            return
        }
        arrowLabelView.setText(text)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let canvas = contentView?.bounds.size ?? frame.size
        let pillWidth = arrowLabelView.frame.width
        let pillHeight = arrowLabelView.frame.height
        let margin: CGFloat = 12
        var x = mid.x - pillWidth / 2
        x = min(max(margin, x), canvas.width - pillWidth - margin)
        var y = mid.y + 12
        if y + pillHeight > canvas.height - margin {
            y = mid.y - 12 - pillHeight
        }
        y = max(margin, y)
        arrowLabelView.setFrameOrigin(NSPoint(x: x, y: y))
        arrowLabelView.alphaValue = 1
    }

    // MARK: - Countdown overlay

    /// Start (or restart) a circular countdown ring that depletes over
    /// `seconds` at the given global screen position. A running countdown is
    /// replaced.
    func showCountdown(seconds: TimeInterval, at point: CGPoint, label: String?) {
        orderFrontRegardless()

        // Cancel any in-flight countdown so a rapid re-call starts clean.
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownLayer.removeAllAnimations()

        let local = toLocal(point)
        let radius: CGFloat = 60
        let ringRect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        // Start the stroke at 12 o'clock and run clockwise so it reads as a
        // clock draining. Rotate the whole layer via its transform — simpler
        // than re-computing the path each tick.
        let ringPath = CGPath(ellipseIn: ringRect, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        countdownTrackLayer.path = ringPath
        countdownLayer.path = ringPath
        countdownLayer.position = local
        countdownTrackLayer.position = local
        countdownLayer.opacity = 1
        countdownTrackLayer.opacity = 0.25
        // Start at 12 o'clock (rotate -90° around the centre).
        let rotation = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        countdownLayer.transform = rotation
        countdownTrackLayer.transform = rotation
        CATransaction.commit()

        let deplete = CABasicAnimation(keyPath: "strokeEnd")
        deplete.fromValue = 1.0
        deplete.toValue = 0.0
        deplete.duration = max(0.1, seconds)
        deplete.timingFunction = CAMediaTimingFunction(name: .linear)
        deplete.fillMode = .forwards
        deplete.isRemovedOnCompletion = false
        countdownLayer.strokeEnd = 0
        countdownLayer.add(deplete, forKey: "deplete")

        // Centred seconds label.
        countdownTextField.stringValue = "\(Int(ceil(seconds)))"
        let fieldSize = NSSize(width: radius * 1.6, height: 36)
        countdownTextField.frame = NSRect(
            x: local.x - fieldSize.width / 2,
            y: local.y - fieldSize.height / 2,
            width: fieldSize.width,
            height: fieldSize.height
        )
        countdownTextField.alphaValue = 1
        if let label, !label.isEmpty {
            // Append the label below the big number via a second line. Kept
            // single-field for simplicity — the field is multi-line when
            // usesSingleLineMode is false.
            countdownTextField.stringValue = "\(Int(ceil(seconds)))\n\(label)"
        }
        isCountdownVisible = true

        let endsAt = Date().addingTimeInterval(seconds)
        countdownEndsAt = endsAt
        // 250ms tick: update the whole-second number and fire one haptic tick
        // per whole-second boundary so the user feels the tempo. The closure
        // captures `endsAt` by value and does not touch the timer itself, so
        // it's safe to hop back to the MainActor without passing state across.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.advanceCountdownTick(label: label, endsAt: endsAt)
                }
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        fadeLayerIn(countdownLayer, duration: Self.reduceMotion ? 0.05 : 0.2)
    }

    /// Hide the countdown ring immediately.
    func hideCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEndsAt = nil
        guard isCountdownVisible else { return }
        isCountdownVisible = false
        fadeLayerOut(countdownLayer, duration: Self.reduceMotion ? 0.05 : 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.countdownLayer.removeAllAnimations()
                self?.countdownLayer.path = nil
                self?.countdownTrackLayer.path = nil
                self?.countdownTrackLayer.opacity = 0
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            countdownTextField.animator().alphaValue = 0
        }
    }

    private var lastCountdownWholeSecond: Int = -1

    private func advanceCountdownTick(label: String?, endsAt: Date) {
        let remaining = endsAt.timeIntervalSinceNow
        if remaining <= 0 {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownTextField.stringValue = "0"
            hideCountdown()
            return
        }
        let whole = Int(ceil(remaining))
        if whole != lastCountdownWholeSecond {
            lastCountdownWholeSecond = whole
            if let label, !label.isEmpty {
                countdownTextField.stringValue = "\(whole)\n\(label)"
            } else {
                countdownTextField.stringValue = "\(whole)"
            }
            // Light haptic tick per whole-second boundary.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: - Scroll hint overlay

    /// Direction for the `scroll_hint` tool — matches `ScrollHintTool`.
    enum ScrollDirection: String { case up, down, left, right }

    /// Show a pulsing chevron pinned to the given edge of the visible frame.
    func showScrollHint(direction: ScrollDirection, label: String?, holdSeconds: TimeInterval) {
        orderFrontRegardless()
        pendingScrollHintHide?.cancel()
        pendingScrollHintHide = nil

        let symbolName = switch direction {
        case .up: "chevron.compact.up"
        case .down: "chevron.compact.down"
        case .left: "chevron.compact.left"
        case .right: "chevron.compact.right"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .bold, scale: .large)
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Scroll hint"
        )?.withSymbolConfiguration(config) {
            scrollHintImageView.image = image
        }
        scrollHintImageView.contentTintColor = NSColor.systemOrange
        scrollHintImageView.sizeToFit()

        // Pin to the appropriate edge of visibleFrame (not frame) so the
        // chevron clears the menu bar / notch on MacBooks.
        let canvas = contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        let visible = (screen?.visibleFrame ?? frame).offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)
        let size = scrollHintImageView.frame.size
        let edgePad: CGFloat = 40
        var origin = NSPoint.zero
        switch direction {
        case .up:
            origin = NSPoint(x: canvas.midX - size.width / 2, y: visible.maxY - size.height - edgePad)
        case .down:
            origin = NSPoint(x: canvas.midX - size.width / 2, y: visible.minY + edgePad)
        case .left:
            origin = NSPoint(x: visible.minX + edgePad, y: canvas.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: visible.maxX - size.width - edgePad, y: canvas.midY - size.height / 2)
        }
        scrollHintImageView.setFrameOrigin(origin)
        scrollHintImageView.alphaValue = 1

        // Translation animation: chevron nudges toward the hinted direction
        // and back in an autoreverse loop so it reads as "keep going this way".
        let nudge: CGFloat = 10
        let (dx, dy): (CGFloat, CGFloat)
        switch direction {
        case .up: (dx, dy) = (0, nudge)
        case .down: (dx, dy) = (0, -nudge)
        case .left: (dx, dy) = (-nudge, 0)
        case .right: (dx, dy) = (nudge, 0)
        }
        scrollHintImageView.wantsLayer = true
        scrollHintImageView.layer?.removeAllAnimations()
        let translate = CABasicAnimation(keyPath: "transform.translation")
        translate.fromValue = NSValue(size: CGSize(width: 0, height: 0))
        translate.toValue = NSValue(size: CGSize(width: dx, height: dy))
        translate.duration = 0.7
        translate.autoreverses = true
        translate.repeatCount = .infinity
        translate.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scrollHintImageView.layer?.add(translate, forKey: "nudge")

        // Optional label: anchor above chevron (or beside it for left/right).
        if let label, !label.isEmpty {
            scrollHintLabelView.setText(label)
            let pillWidth = scrollHintLabelView.frame.width
            let pillHeight = scrollHintLabelView.frame.height
            let labelOrigin = switch direction {
            case .up:
                NSPoint(x: origin.x + size.width / 2 - pillWidth / 2, y: origin.y - pillHeight - 8)
            case .down:
                NSPoint(x: origin.x + size.width / 2 - pillWidth / 2, y: origin.y + size.height + 8)
            case .left:
                NSPoint(x: origin.x + size.width + 8, y: origin.y + size.height / 2 - pillHeight / 2)
            case .right:
                NSPoint(x: origin.x - pillWidth - 8, y: origin.y + size.height / 2 - pillHeight / 2)
            }
            scrollHintLabelView.setFrameOrigin(labelOrigin)
            scrollHintLabelView.alphaValue = 1
        } else {
            scrollHintLabelView.fadeOut(duration: 0.1)
        }

        isScrollHintVisible = true
        let hold = min(max(holdSeconds, 0.5), 120.0)
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hideScrollHint() }
        }
        pendingScrollHintHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: hide)
    }

    func hideScrollHint() {
        pendingScrollHintHide?.cancel()
        pendingScrollHintHide = nil
        guard isScrollHintVisible else { return }
        isScrollHintVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            scrollHintImageView.animator().alphaValue = 0
            scrollHintLabelView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.scrollHintImageView.layer?.removeAllAnimations()
            }
        }
    }

    // MARK: - Shortcut HUD overlay

    /// A single rendered keycap — the parser hands us these so the panel
    /// stays ignorant of which tokens are modifiers vs. plain letters.
    struct ShortcutKey: Sendable {
        /// The glyph / text rendered inside the rounded key ("⌘", "S", "⏎").
        let glyph: String
        /// True for modifier glyphs (⌘ ⇧ ⌥ ⌃) — slightly different styling.
        let isModifier: Bool
    }

    func showShortcut(keys: [ShortcutKey], label: String?, holdSeconds: TimeInterval) {
        orderFrontRegardless()
        pendingShortcutHide?.cancel()
        pendingShortcutHide = nil

        // Tear down any existing keycap subviews so rapid re-calls don't stack.
        for view in shortcutKeysStack.arrangedSubviews {
            shortcutKeysStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for key in keys {
            let keyView = makeShortcutKeyView(key)
            shortcutKeysStack.addArrangedSubview(keyView)
        }

        if let label, !label.isEmpty {
            shortcutLabelField.stringValue = label
            shortcutLabelField.isHidden = false
        } else {
            shortcutLabelField.stringValue = ""
            shortcutLabelField.isHidden = true
        }

        // Size and centre the HUD. Use the visibleFrame so it doesn't sit
        // behind the notch / menu bar on notched MacBooks.
        shortcutHUDView.layoutSubtreeIfNeeded()
        let intrinsicSize = shortcutHUDView.fittingSize
        let hudSize = NSSize(
            width: max(intrinsicSize.width, 240),
            height: max(intrinsicSize.height, 96)
        )
        let visible = (screen?.visibleFrame ?? frame).offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)
        let origin = NSPoint(
            x: visible.midX - hudSize.width / 2,
            y: visible.midY - hudSize.height / 2
        )
        shortcutHUDView.frame = NSRect(origin: origin, size: hudSize)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.reduceMotion ? 0.05 : 0.2
            shortcutHUDView.animator().alphaValue = 1
        }
        isShortcutHUDVisible = true

        let hold = min(max(holdSeconds, 0.5), 120.0)
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hideShortcut() }
        }
        pendingShortcutHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: hide)
    }

    func hideShortcut() {
        pendingShortcutHide?.cancel()
        pendingShortcutHide = nil
        guard isShortcutHUDVisible else { return }
        isShortcutHUDVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.reduceMotion ? 0.05 : 0.2
            shortcutHUDView.animator().alphaValue = 0
        }
    }

    /// Builds one rounded keycap NSView for the given key.
    private func makeShortcutKeyView(_ key: ShortcutKey) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let field = NSTextField(labelWithString: key.glyph)
        field.font = .monospacedSystemFont(ofSize: 22, weight: key.isModifier ? .semibold : .medium)
        field.textColor = .white
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        // Key caps are a square by default; wide glyphs like "enter" or
        // "space" get an extra-wide variant.
        let isWide = key.glyph.count > 2
        let width: CGFloat = isWide ? 72 : 48
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: 48),
            field.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Hide every overlay at once — used on panel teardown so nothing
    /// lingers past the end of an agent turn.
    func hideAllOverlays() {
        hideHighlight()
        hideArrow()
        hideCountdown()
        hideScrollHint()
        hideShortcut()
    }

    // MARK: - NSPanel Overrides

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Private

    private func configureLayers() {
        guard let rootLayer = contentView?.layer else { return }

        // Match the host display's backing scale so the cursor renders with
        // full retina fidelity. Without this the 32pt image blits at 1x on
        // 2x displays and looks slightly soft. We also render the source
        // bitmap at `scale`x inside `tintedCursorImage` so the `contents`
        // CGImage actually carries the extra pixels.
        let scale = backingScaleFactor()

        // Outline (white halo) — slightly larger than the cursor, sits behind.
        let outlineSize = Self.cursorSize + Self.outlinePadding * 2
        outlineLayer.bounds = CGRect(x: 0, y: 0, width: outlineSize, height: outlineSize)
        outlineLayer.contents = tintedCursorImage(color: .white, scale: scale)
        outlineLayer.contentsGravity = .resizeAspect
        outlineLayer.contentsScale = scale
        outlineLayer.opacity = 0
        outlineLayer.anchorPoint = anchorForArrowTip()
        outlineLayer.shadowColor = NSColor.black.cgColor
        outlineLayer.shadowOpacity = 0.35
        outlineLayer.shadowOffset = CGSize(width: 0, height: -1)
        outlineLayer.shadowRadius = 3
        rootLayer.addSublayer(outlineLayer)

        // Cursor glyph — real macOS arrow tinted Tama orange at 70% opacity.
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: Self.cursorSize, height: Self.cursorSize)
        cursorLayer.contents = tintedCursorImage(
            color: NSColor.systemOrange.withAlphaComponent(0.9),
            scale: scale
        )
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.contentsScale = scale
        cursorLayer.opacity = 0
        cursorLayer.anchorPoint = anchorForArrowTip()
        rootLayer.addSublayer(cursorLayer)

        // Pulse ring.
        pulseLayer.fillColor = NSColor.clear.cgColor
        pulseLayer.strokeColor = NSColor.systemOrange.cgColor
        pulseLayer.lineWidth = 3
        pulseLayer.contentsScale = scale
        pulseLayer.opacity = 0
        rootLayer.addSublayer(pulseLayer)
    }

    /// Adds the highlight / arrow / countdown layers and configures their
    /// static styling. Called from `init` BEFORE `configureLayers()` so the
    /// cursor and its pulse ring sit on top of these overlays in the render
    /// tree.
    private func configureOverlayLayers() {
        guard let rootLayer = contentView?.layer else { return }
        let scale = backingScaleFactor()

        // Highlight — dashed orange outline with a faint orange tint fill.
        highlightLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor
        highlightLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.95).cgColor
        highlightLayer.lineWidth = 3
        highlightLayer.lineDashPattern = [8, 4]
        highlightLayer.contentsScale = scale
        highlightLayer.opacity = 0
        rootLayer.addSublayer(highlightLayer)

        // Arrow — filled orange with a thin dark edge for contrast.
        arrowLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        arrowLayer.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        arrowLayer.lineWidth = 0.5
        arrowLayer.lineJoin = .round
        arrowLayer.contentsScale = scale
        arrowLayer.opacity = 0
        rootLayer.addSublayer(arrowLayer)

        // Countdown — hollow ring (track) + depleting ring on top.
        countdownTrackLayer.fillColor = NSColor.clear.cgColor
        countdownTrackLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
        countdownTrackLayer.lineWidth = 4
        countdownTrackLayer.contentsScale = scale
        countdownTrackLayer.opacity = 0
        rootLayer.addSublayer(countdownTrackLayer)

        countdownLayer.fillColor = NSColor.clear.cgColor
        countdownLayer.strokeColor = NSColor.systemOrange.cgColor
        countdownLayer.lineWidth = 4
        countdownLayer.lineCap = .round
        countdownLayer.contentsScale = scale
        countdownLayer.opacity = 0
        rootLayer.addSublayer(countdownLayer)

        // Countdown number label — added as a subview, centred on demand.
        countdownTextField.alignment = .center
        countdownTextField.textColor = .white
        countdownTextField.backgroundColor = .clear
        countdownTextField.isBezeled = false
        countdownTextField.isEditable = false
        countdownTextField.isSelectable = false
        countdownTextField.usesSingleLineMode = false
        countdownTextField.maximumNumberOfLines = 2
        countdownTextField.font = .systemFont(ofSize: 24, weight: .semibold)
        countdownTextField.alphaValue = 0
        contentView?.addSubview(countdownTextField)

        // Scroll-hint — pre-configure a chevron image view that we fill in
        // per call (image and position change; rest is static).
        scrollHintImageView.imageScaling = .scaleProportionallyUpOrDown
        scrollHintImageView.alphaValue = 0

        // Shortcut HUD — vibrancy backdrop with a rounded card and a
        // horizontal stack of keycap subviews. Centred per call.
        shortcutHUDView.wantsLayer = true
        shortcutHUDView.layer?.cornerRadius = 18
        shortcutHUDView.layer?.masksToBounds = true
        shortcutHUDView.alphaValue = 0

        shortcutHUDBackground.material = .hudWindow
        shortcutHUDBackground.state = .active
        shortcutHUDBackground.blendingMode = .behindWindow
        shortcutHUDBackground.wantsLayer = true
        shortcutHUDBackground.translatesAutoresizingMaskIntoConstraints = false
        shortcutHUDView.addSubview(shortcutHUDBackground)

        shortcutKeysStack.orientation = .horizontal
        shortcutKeysStack.spacing = 8
        shortcutKeysStack.alignment = .centerY
        shortcutKeysStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutHUDView.addSubview(shortcutKeysStack)

        shortcutLabelField.textColor = NSColor.white.withAlphaComponent(0.85)
        shortcutLabelField.backgroundColor = .clear
        shortcutLabelField.isBezeled = false
        shortcutLabelField.isEditable = false
        shortcutLabelField.isSelectable = false
        shortcutLabelField.alignment = .center
        shortcutLabelField.font = .systemFont(ofSize: 13, weight: .medium)
        shortcutLabelField.translatesAutoresizingMaskIntoConstraints = false
        shortcutHUDView.addSubview(shortcutLabelField)

        NSLayoutConstraint.activate([
            shortcutHUDBackground.leadingAnchor.constraint(equalTo: shortcutHUDView.leadingAnchor),
            shortcutHUDBackground.trailingAnchor.constraint(equalTo: shortcutHUDView.trailingAnchor),
            shortcutHUDBackground.topAnchor.constraint(equalTo: shortcutHUDView.topAnchor),
            shortcutHUDBackground.bottomAnchor.constraint(equalTo: shortcutHUDView.bottomAnchor),

            shortcutKeysStack.centerXAnchor.constraint(equalTo: shortcutHUDView.centerXAnchor),
            shortcutKeysStack.topAnchor.constraint(equalTo: shortcutHUDView.topAnchor, constant: 20),

            shortcutLabelField.centerXAnchor.constraint(equalTo: shortcutHUDView.centerXAnchor),
            shortcutLabelField.topAnchor.constraint(equalTo: shortcutKeysStack.bottomAnchor, constant: 10),
            shortcutLabelField.leadingAnchor.constraint(
                greaterThanOrEqualTo: shortcutHUDView.leadingAnchor,
                constant: 20
            ),
            shortcutLabelField.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutHUDView.trailingAnchor,
                constant: -20
            ),
            shortcutLabelField.bottomAnchor.constraint(
                lessThanOrEqualTo: shortcutHUDView.bottomAnchor,
                constant: -16
            ),
        ])
    }

    // MARK: - Shared overlay animation helpers

    /// Fade a CALayer from its current opacity up to 1.0.
    private func fadeLayerIn(_ layer: CALayer, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.opacity = 1
        layer.add(fade, forKey: "overlayFadeIn")
    }

    /// Fade a CALayer from its current opacity to 0, then invoke `completion`.
    private func fadeLayerOut(
        _ layer: CALayer,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(fade, forKey: "overlayFadeOut")
        if let completion {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
                completion()
            }
        }
    }

    /// Convert an AppKit-space (bottom-left origin) rect in global screen
    /// coordinates to the panel's local space. Panel-local coords are also
    /// bottom-left / y-up so this is a pure translation.
    private func toLocalRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x - frame.origin.x,
            y: rect.origin.y - frame.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// Returns the backing scale of the screen the panel is on, or the main
    /// screen's as a fallback. Read lazily because `self.screen` isn't set
    /// until after the panel is ordered front.
    private func backingScaleFactor() -> CGFloat {
        screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    /// Anchor point so the "tip" of the arrow sits exactly at the layer's
    /// `position`. Read from the authoritative macOS value `NSCursor.arrow.hotSpot`
    /// rather than hardcoding an approximation — this keeps the tip accurate
    /// even if Apple tweaks the cursor image in future macOS versions.
    ///
    /// `hotSpot` is expressed in the cursor image's top-down coordinate space
    /// (y increases downward), whereas `CALayer.anchorPoint` is bottom-up with
    /// (0, 0) = bottom-left and (1, 1) = top-right — hence the Y flip.
    private func anchorForArrowTip() -> CGPoint {
        let hotSpot = NSCursor.arrow.hotSpot
        let imageSize = NSCursor.arrow.image.size
        // Defensive fallback — if macOS ever returns a zero-size image,
        // the (4, 4) hotspot on a 24pt image ≈ (0.167, 0.833).
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGPoint(x: 0.167, y: 0.833)
        }
        return CGPoint(
            x: hotSpot.x / imageSize.width,
            y: 1.0 - hotSpot.y / imageSize.height
        )
    }

    /// Build a tinted version of `NSCursor.arrow.image` for use as a layer's
    /// `contents`. We render the system arrow through a colour fill so the
    /// virtual cursor has a distinct Tama-brand tint but still reads as a
    /// cursor. Rendered at `scale`x native pixels so the CGImage carries
    /// enough pixels to match the layer's `contentsScale` on retina displays.
    private func tintedCursorImage(color: NSColor, scale: CGFloat) -> CGImage? {
        let source = NSCursor.arrow.image
        let logicalSize = NSSize(width: Self.cursorSize, height: Self.cursorSize)
        // Render into a bitmap rep at `scale`x so the resulting CGImage
        // has (cursorSize * scale) pixels in each dimension.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.cursorSize * scale),
            pixelsHigh: Int(Self.cursorSize * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = logicalSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let rect = NSRect(origin: .zero, size: logicalSize)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)

        return rep.cgImage
    }

    /// Convert a point in global screen coordinates to the panel's local
    /// (flipped-upward AppKit) coordinate space.
    private func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - frame.origin.x + Self.tipOffset.x,
            y: point.y - frame.origin.y + Self.tipOffset.y
        )
    }

    private func updateLabel(_ text: String?, at point: CGPoint, animateDuration: TimeInterval = 0) {
        guard let text, !text.isEmpty else {
            labelView.fadeOut(duration: 0.15)
            return
        }
        labelView.setText(text)
        panelLogger.debug("updateLabel cursorAnchor=\(point.debugDescription) text=\(text)")

        // The panel covers the whole display; the content view's bounds are
        // the same as the screen size in local coordinates. Use that to keep
        // the pill on-screen on every side.
        let canvas = contentView?.bounds.size ?? frame.size

        // Position the pill to the right of the cursor tip by default. If it
        // would extend past the right edge, flip it to the left of the
        // cursor so the entire label stays visible.
        let gap: CGFloat = Self.cursorSize * 0.6
        let pillWidth = labelView.frame.width
        let pillHeight = labelView.frame.height
        let screenMargin: CGFloat = 12

        var x = point.x + gap
        if x + pillWidth > canvas.width - screenMargin {
            // Flip to the left of the cursor.
            x = point.x - gap - pillWidth
        }
        x = max(screenMargin, x)

        // Place the pill just below the arrow tip. If that would clip the
        // bottom of the display, raise it above the cursor.
        var y = point.y + Self.cursorSize * 0.4
        if y + pillHeight > canvas.height - screenMargin {
            y = point.y - Self.cursorSize * 0.4 - pillHeight
        }
        y = max(screenMargin, y)

        let desiredOrigin = NSPoint(x: x, y: y)
        if animateDuration > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animateDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                labelView.animator().setFrameOrigin(desiredOrigin)
                labelView.animator().alphaValue = 1
            }
        } else {
            labelView.setFrameOrigin(desiredOrigin)
            labelView.alphaValue = 1
        }
    }
}

// MARK: - Label View

/// A small rounded pill that renders next to the virtual cursor to caption
/// what it's pointing at ("File menu", "Export button", etc.).
///
/// We manage the pill's frame manually (it shrinks/grows with the label text)
/// so children use frame-based layout too — auto-layout would fight with the
/// external `setFrameOrigin` calls and surface constraint warnings.
@MainActor
private final class VirtualCursorLabelView: NSView {
    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let textField = NSTextField(labelWithString: "")

    // Generous padding so the text is never visually clipped by the pill's
    // rounded corners. Previous values (10h / 4v) felt cramped, especially
    // on HiDPI where the corner radius eats the first few pixels of glyphs.
    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 7
    private static let minPillWidth: CGFloat = 56
    private static let cornerRadius: CGFloat = 10
    /// Extra pixels added to the computed text width before padding. NSTextField's
    /// `intrinsicContentSize` rounds down kerning/overshoot for some fonts, so the
    /// last glyph gets shaved by `masksToBounds`. A small safety buffer guarantees
    /// the full label renders even for strings ending in wide characters like
    /// "w" / "m" / italic descenders.
    private static let glyphSafetyBuffer: CGFloat = 4

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        // Darken the vibrancy slightly so white text always has enough
        // contrast — over a bright wallpaper the plain HUD material can
        // wash out.
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        // 12pt medium is compact but readable on HiDPI. The pill grows to
        // fit whatever the agent passes; the agent is instructed to keep
        // labels to 1–3 words so the pill never gets unwieldy.
        textField.font = .systemFont(ofSize: 12, weight: .medium)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.usesSingleLineMode = true
        // Never clip — the label is the whole point of the pill. The agent
        // keeps labels short; we make sure they always render in full.
        textField.lineBreakMode = .byClipping
        addSubview(textField)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setText(_ text: String) {
        textField.stringValue = text
        let metrics = measuredTextSize(text)
        // Size the pill to the measured text plus equal padding on each side,
        // with a minimum width so very short labels still look like pills.
        // No maximum — truncation hides the actual guidance, which defeats
        // the whole point of this tool.
        let targetWidth = metrics.width + Self.horizontalPadding * 2
        let width = max(targetWidth, Self.minPillWidth)
        let height = metrics.height + Self.verticalPadding * 2
        setFrameSize(NSSize(width: width, height: height))
    }

    /// Measures the rendered size of `text` using the actual font metrics
    /// (kerning, overshoot, leading) instead of `NSTextField.intrinsicContentSize`,
    /// which rounds the trailing glyph's advance width down and causes the last
    /// character to clip against `masksToBounds`. Width is rounded up and a
    /// small safety buffer is added for wide-trailing glyphs like w/m.
    private func measuredTextSize(_ text: String) -> CGSize {
        let font = textField.font ?? .systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let raw = (text as NSString).size(withAttributes: attributes)
        return CGSize(
            width: ceil(raw.width) + Self.glyphSafetyBuffer,
            height: ceil(raw.height)
        )
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        tint.frame = bounds
        let metrics = measuredTextSize(textField.stringValue)
        // Center the text vertically in the pill. The text field gets the
        // full horizontal inset on each side so there's always clear air
        // between glyphs and the pill's rounded corners.
        textField.frame = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - metrics.height) / 2,
            width: bounds.width - Self.horizontalPadding * 2,
            height: metrics.height
        )
    }

    func fadeOut(duration: TimeInterval) {
        guard alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = 0
        }
    }
}

// MARK: - CGPath arrow geometry

extension CGPath {
    /// Build a filled arrow polygon from `start` to `end` with the given
    /// tail/head widths and head length. Adapted from Rob Mayoff's widely
    /// cited Swift arrow gist (https://gist.github.com/mayoff/4146780) and
    /// `dagronf/AppKitFocusOverlay`'s MIT-licensed implementation of the
    /// same pattern: lay out 7 axis-aligned points, then rotate via a
    /// `CGAffineTransform` to align the arrow along the start→end vector.
    static func tamaArrow(
        from start: CGPoint,
        to end: CGPoint,
        tailWidth: CGFloat,
        headWidth: CGFloat,
        headLength: CGFloat
    ) -> CGPath {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return CGMutablePath() }
        let tailLength = max(0, length - headLength)

        let points: [CGPoint] = [
            CGPoint(x: 0, y: tailWidth / 2),
            CGPoint(x: tailLength, y: tailWidth / 2),
            CGPoint(x: tailLength, y: headWidth / 2),
            CGPoint(x: length, y: 0),
            CGPoint(x: tailLength, y: -headWidth / 2),
            CGPoint(x: tailLength, y: -tailWidth / 2),
            CGPoint(x: 0, y: -tailWidth / 2),
        ]

        let cosine = (end.x - start.x) / length
        let sine = (end.y - start.y) / length
        let transform = CGAffineTransform(
            a: cosine,
            b: sine,
            c: -sine,
            d: cosine,
            tx: start.x,
            ty: start.y
        )

        let path = CGMutablePath()
        path.addLines(between: points, transform: transform)
        path.closeSubpath()
        return path
    }
}
