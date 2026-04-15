import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "callbutton"
)

/// A persistent "Call Tama" button that extends seamlessly from the left side of the hardware notch.
///
/// The button is drawn as a black wing shape whose right edge is flush with the notch,
/// making it appear as a natural left-side extension of the notch itself. Uses a non-activating
/// `NSPanel` so it never steals focus. On non-notch displays, falls back to a centered notch shape.
@MainActor
enum NotchCallButton {
    // MARK: - State

    private static var panel: NSPanel?
    private static var shapeLayer: CAShapeLayer?
    private static var hoverLayer: CALayer?
    private static var isVisible = false
    private(set) static var isInCall = false
    private static var labelField: NSTextField?
    private static var callSession: CallSession?

    /// Whether the panel is temporarily hidden because a notch overlay is active.
    private static var isHiddenByOverlay = false

    // MARK: - Constants

    /// Width of the wing extension.
    private static let wingWidth: CGFloat = 120

    /// Top corner radius on the left side (matches notch curvature).
    private static let topCornerRadius: CGFloat = 6

    /// Bottom corner radius (matching notch aesthetic).
    private static let bottomCornerRadius: CGFloat = 10

    private static let expandDuration: TimeInterval = 0.4
    private static let collapseDuration: TimeInterval = 0.25

    // MARK: - Public API

    /// Show the call button joined to the notch.
    static func show() {
        guard !isVisible else { return }
        guard let screen = NSScreen.main else { return }

        logger.info("Showing call button")
        isVisible = true

        let notchSize = screen.notchSize
        let screenFrame = screen.frame

        // Wing is exactly the same height as the notch.
        let wingHeight = notchSize.height
        let windowWidth = wingWidth
        let windowHeight = wingHeight

        // Position: overlap into the notch so the wing blends seamlessly.
        let notchLeftX = screenFrame.midX - notchSize.width / 2
        let originX = notchLeftX - windowWidth + topCornerRadius + 8
        let originY = screenFrame.maxY - windowHeight

        let newPanel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
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
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.appearance = NSAppearance(named: .darkAqua)

        // Flipped root view (y=0 at top) — same pattern as NotchActivityIndicator.
        let rootView = FlippedCallButtonView(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        )
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        // Shape layer: black wing joined to notch.
        let shape = CAShapeLayer()
        shape.fillColor = NSColor.black.cgColor

        let wingRect = CGRect(x: 0, y: 0, width: wingWidth, height: wingHeight)
        shape.path = leftWingPath(in: wingRect)
        shape.frame = rootView.bounds
        rootView.layer?.addSublayer(shape)

        // 1px bridge at the top-right to eliminate subpixel gap with hardware notch.
        let bridgeLayer = CALayer()
        bridgeLayer.backgroundColor = NSColor.black.cgColor
        bridgeLayer.frame = CGRect(
            x: wingRect.maxX - 1,
            y: 0,
            width: 2,
            height: wingHeight
        )
        rootView.layer?.addSublayer(bridgeLayer)

        // Hover highlight layer (clipped to the wing shape).
        let hover = CAShapeLayer()
        hover.path = shape.path
        hover.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hover.opacity = 0
        hover.frame = rootView.bounds
        rootView.layer?.addSublayer(hover)

        // Text label centered in the wing area.
        let labelHeight: CGFloat = 16
        let labelY = (wingHeight - labelHeight) / 2
        let label = makeLabel()
        label.frame = NSRect(
            x: bottomCornerRadius,
            y: labelY,
            width: wingWidth - bottomCornerRadius - 4,
            height: labelHeight
        )
        // Start with label invisible for fade-in.
        label.alphaValue = 0
        rootView.addSubview(label)
        labelField = label

        // Click overlay.
        let overlay = CallButtonOverlay(frame: rootView.bounds)
        overlay.autoresizingMask = [.width, .height]
        rootView.addSubview(overlay)

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        panel = newPanel
        shapeLayer = shape
        hoverLayer = hover

        // Animate wing expanding from notch edge.
        animateExpand(shapeLayer: shape, hoverLayer: hover, label: label, wingHeight: wingHeight)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reposition()
            }
        }

        // Hide when notch overlays appear, restore when they clear.
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

        // If an overlay is already active, hide immediately.
        if NotchOverlayTracker.isActive {
            hideForOverlay()
        }
    }

    /// Hide and tear down the call button with a collapse animation.
    static func hide() {
        guard isVisible else { return }
        logger.info("Hiding call button")
        isVisible = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(self, name: .notchOverlayActive, object: nil)
        NotificationCenter.default.removeObserver(self, name: .notchOverlayInactive, object: nil)
        isHiddenByOverlay = false

        if isInCall {
            isInCall = false
            NotchCallTimer.hide()
        }

        guard let panel, let shapeLayer else {
            teardown()
            return
        }

        // Fade out label immediately.
        if let labelField {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                labelField.animator().alphaValue = 0
            }
        }

        // Collapse shape back to notch edge.
        let wingHeight = panel.frame.height
        let collapsedPath = collapsedWingPath(wingHeight: wingHeight)

        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = shapeLayer.path
        pathAnimation.toValue = collapsedPath
        pathAnimation.damping = 18
        pathAnimation.stiffness = 220
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "collapsePath")
        shapeLayer.path = collapsedPath

        // After collapse, fade out and remove.
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    teardown()
                }
            }
        }
    }

    /// Temporarily hide the call button panel while a notch overlay is active.
    private static func hideForOverlay() {
        guard isVisible, !isHiddenByOverlay else { return }
        isHiddenByOverlay = true
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        if isInCall { NotchCallTimer.hideForOverlay() }
    }

    /// Restore the call button panel after notch overlays clear, with expand animation.
    private static func showAfterOverlay() {
        guard isVisible, isHiddenByOverlay else { return }
        isHiddenByOverlay = false

        guard let panel, let shapeLayer else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Re-run the expand animation so it slides in cleanly.
        let wingHeight = panel.frame.height
        if let label = labelField {
            label.alphaValue = 0
            animateExpand(shapeLayer: shapeLayer, hoverLayer: hoverLayer!, label: label, wingHeight: wingHeight)
        }

        if isInCall { NotchCallTimer.showAfterOverlay() }
    }

    private static func teardown() {
        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
        hoverLayer = nil
        labelField = nil
    }

    /// Called when the button is tapped.
    fileprivate static func handleTap() {
        ButtonSound.shared.play()
        if isInCall {
            endCall()
        } else {
            startCall()
        }
    }

    /// Begin a call — switch label to "Disconnect", show the timer wing, and start the voice session.
    private static func startCall() {
        logger.info("Call started")
        isInCall = true
        updateLabel(disconnect: true)
        NotchCallTimer.show()

        let session = CallSession()
        callSession = session
        session.start()
    }

    /// End a call — revert label to "Call Tama", hide the timer wing, and stop the voice session.
    static func endCall() {
        logger.info("Call ended")
        isInCall = false
        isHiddenByOverlay = false
        updateLabel(disconnect: false)
        NotchCallTimer.hide()

        // Show the button panel if it was hidden by an overlay (e.g. tool indicator).
        if let panel, panel.parent == nil, isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        callSession?.end()
        callSession = nil
    }

    /// Update the label text and icon tint based on call state.
    private static func updateLabel(disconnect: Bool) {
        guard let labelField else { return }
        let iconAttachment = NSTextAttachment()
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        if let iconImage = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: "Call")?
            .withSymbolConfiguration(iconConfig)
        {
            iconAttachment.image = iconImage
        }
        let iconColor: NSColor = disconnect
            ? NSColor.systemRed.withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.85)
        let textColor: NSColor = disconnect
            ? NSColor.white.withAlphaComponent(0.85)
            : NSColor.white.withAlphaComponent(0.85)
        let iconString = NSMutableAttributedString(attachment: iconAttachment)
        iconString.addAttributes(
            [.foregroundColor: iconColor],
            range: NSRange(location: 0, length: iconString.length)
        )
        let text = disconnect ? " Disconnect" : " Call Tama"
        let textString = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: textColor,
            ]
        )
        iconString.append(textString)
        labelField.attributedStringValue = iconString
    }

    /// Show hover highlight.
    fileprivate static func setHovered(_ hovered: Bool) {
        guard let hoverLayer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = hoverLayer.opacity
        animation.toValue = hovered ? Float(1.0) : Float(0)
        animation.duration = 0.15
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        hoverLayer.add(animation, forKey: "hover")
        hoverLayer.opacity = hovered ? 1.0 : 0
    }

    // MARK: - Animation

    /// A thin sliver path at the notch-touching (right) edge — the starting state for expand.
    private static func collapsedWingPath(wingHeight: CGFloat) -> CGPath {
        let tr = topCornerRadius
        let rect = CGRect(x: wingWidth - tr - 2, y: 0, width: tr + 2, height: wingHeight)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - tr))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private static func animateExpand(
        shapeLayer: CAShapeLayer,
        hoverLayer: CALayer,
        label: NSTextField,
        wingHeight: CGFloat
    ) {
        let collapsedPath = collapsedWingPath(wingHeight: wingHeight)
        let expandedPath = leftWingPath(in: CGRect(x: 0, y: 0, width: wingWidth, height: wingHeight))

        // Start from collapsed.
        shapeLayer.path = collapsedPath
        if let hoverShape = hoverLayer as? CAShapeLayer {
            hoverShape.path = collapsedPath
        }

        // Spring animate to full wing.
        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = collapsedPath
        pathAnimation.toValue = expandedPath
        pathAnimation.damping = 14
        pathAnimation.stiffness = 180
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "expandPath")
        shapeLayer.path = expandedPath

        // Also animate the hover layer shape.
        if let hoverShape = hoverLayer as? CAShapeLayer {
            let hoverPathAnim = CASpringAnimation(keyPath: "path")
            hoverPathAnim.fromValue = collapsedPath
            hoverPathAnim.toValue = expandedPath
            hoverPathAnim.damping = 14
            hoverPathAnim.stiffness = 180
            hoverPathAnim.mass = 1.0
            hoverPathAnim.initialVelocity = 0
            hoverPathAnim.duration = hoverPathAnim.settlingDuration
            hoverPathAnim.isRemovedOnCompletion = false
            hoverPathAnim.fillMode = .forwards
            hoverShape.add(hoverPathAnim, forKey: "expandPath")
            hoverShape.path = expandedPath
        }

        // Fade in label after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                label.animator().alphaValue = 1.0
            }
        }
    }

    // MARK: - Positioning

    private static func reposition() {
        guard isVisible, let panel, let screen = NSScreen.main else { return }
        let notchSize = screen.notchSize
        let screenFrame = screen.frame
        let windowWidth = wingWidth
        let windowHeight = notchSize.height
        let notchLeftX = screenFrame.midX - notchSize.width / 2
        let originX = notchLeftX - windowWidth + topCornerRadius + 8
        let originY = screenFrame.maxY - windowHeight
        panel.setFrame(NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight), display: true)
    }

    // MARK: - Wing Path

    /// Generates a path for the left wing shape that joins the notch on its right edge.
    ///
    /// The right side body is inset by `topCornerRadius`, then flares out to the full
    /// width at both top and bottom — the same quad-curve wing pattern used by
    /// `NotchShapePath` for its top corners. This makes the wing look like a seamless
    /// extension of the hardware notch.
    ///
    /// ```
    /// ──────────────┐  ← flat top at full width (flush with notch)
    /// ╲            ╱   ← top-left & top-right: inward quad curves (wing flare)
    /// │          │     ← body: sides inset by topCornerRadius
    /// ╰────────╲       ← bottom-left: outward curve, bottom-right: inward quad curve (wing flare)
    ///           ┘      ← bottom at full width (flush with notch)
    /// ```
    private static func leftWingPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tr = topCornerRadius
        let br = bottomCornerRadius

        // Start at top-left corner (flat top edge).
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top edge → right at full width (flush with notch).
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Top-right: inward quad curve — flares from full width down to body.
        // Mirrors the NotchShapePath top-left pattern.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        // Right side straight down (body is inset by tr from the notch edge).
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - tr))

        // Bottom-right: inward quad curve — body flares back out to full width.
        // Mirrors the top-right curve.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )

        // Bottom edge ← left.
        path.addLine(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY))

        // Bottom-left corner: outward curve.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.maxY - br),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // Left side straight up to the top-left corner area.
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr))

        // Top-left corner: inward quad curve (matches notch curvature).
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    // MARK: - Label

    private static func makeLabel() -> NSTextField {
        let iconAttachment = NSTextAttachment()
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        if let iconImage = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: "Call")?
            .withSymbolConfiguration(iconConfig)
        {
            iconAttachment.image = iconImage
        }
        let iconString = NSMutableAttributedString(attachment: iconAttachment)
        iconString.addAttributes(
            [.foregroundColor: NSColor.white.withAlphaComponent(0.85)],
            range: NSRange(location: 0, length: iconString.length)
        )

        let textString = NSAttributedString(
            string: " Call Tama",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        iconString.append(textString)

        let label = NSTextField(labelWithAttributedString: iconString)
        label.alignment = .center
        return label
    }
}

// MARK: - Flipped View

private final class FlippedCallButtonView: NSView {
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        return layer
    }
}

// MARK: - Click / Hover Overlay

private final class CallButtonOverlay: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        NSCursor.pointingHand.push()
        NotchCallButton.setHovered(true)
    }

    override func mouseExited(with _: NSEvent) {
        NSCursor.pop()
        NotchCallButton.setHovered(false)
    }

    override func mouseDown(with _: NSEvent) {
        NotchCallButton.handleTap()
    }
}
