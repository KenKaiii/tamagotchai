import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "calltimer"
)

/// A live call-duration timer displayed as a right-side wing extending from the hardware notch.
///
/// Mirrors `NotchCallButton` (left wing) but on the right side. Shows an MM:SS timer
/// that counts up from when the call started. Created/destroyed by `NotchCallButton`
/// when the user starts/ends a call.
@MainActor
enum NotchCallTimer {
    // MARK: - State

    private static var panel: NSPanel?
    private static var isVisible = false
    private static var labelField: NSTextField?
    private static var timer: Timer?
    private static var callStartDate: Date?

    private static var shapeLayer: CAShapeLayer?

    // MARK: - Constants

    /// Width of the wing extension.
    private static let wingWidth: CGFloat = 120

    /// Top corner radius on the right side (matches notch curvature).
    private static let topCornerRadius: CGFloat = 6

    /// Bottom corner radius (matching notch aesthetic).
    private static let bottomCornerRadius: CGFloat = 10

    private static let expandDuration: TimeInterval = 0.4
    private static let collapseDuration: TimeInterval = 0.25

    // MARK: - Public API

    /// Show the timer wing joined to the right side of the notch and start counting.
    static func show() {
        guard !isVisible else { return }
        guard let screen = NSScreen.main else { return }

        logger.info("Showing call timer")
        isVisible = true
        callStartDate = Date()

        let notchSize = screen.notchSize
        let screenFrame = screen.frame

        let wingHeight = notchSize.height
        let windowWidth = wingWidth
        let windowHeight = wingHeight

        // Position: right side of notch, overlapping into it.
        let notchRightX = screenFrame.midX + notchSize.width / 2
        let originX = notchRightX - topCornerRadius - 8
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

        // Flipped root view (y=0 at top).
        let rootView = FlippedCallTimerView(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        )
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        // Shape layer: black wing joined to notch.
        let shape = CAShapeLayer()
        shape.fillColor = NSColor.black.cgColor

        let wingRect = CGRect(x: 0, y: 0, width: wingWidth, height: wingHeight)
        shape.path = rightWingPath(in: wingRect)
        shape.frame = rootView.bounds
        rootView.layer?.addSublayer(shape)

        // 1px bridge at the left edge to eliminate subpixel gap with hardware notch.
        let bridgeLayer = CALayer()
        bridgeLayer.backgroundColor = NSColor.black.cgColor
        bridgeLayer.frame = CGRect(
            x: -1,
            y: 0,
            width: 2,
            height: wingHeight
        )
        rootView.layer?.addSublayer(bridgeLayer)

        // Text label centered in the wing area.
        let labelHeight: CGFloat = 16
        let labelY = (wingHeight - labelHeight) / 2
        let label = makeTimerLabel(text: "00:00")
        let labelInset = topCornerRadius + 30
        label.frame = NSRect(
            x: labelInset,
            y: labelY,
            width: wingWidth - labelInset - 4,
            height: labelHeight
        )
        rootView.addSubview(label)
        labelField = label

        // Start with label invisible for fade-in.
        label.alphaValue = 0

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        panel = newPanel
        shapeLayer = shape

        // Animate wing expanding from notch edge.
        animateExpand(shapeLayer: shape, label: label, wingHeight: wingHeight)

        // Start 1-second repeating timer.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                updateTimerLabel()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reposition()
            }
        }
    }

    /// Hide and tear down the timer wing with a collapse animation.
    static func hide() {
        guard isVisible else { return }
        logger.info("Hiding call timer")
        isVisible = false

        timer?.invalidate()
        timer = nil
        callStartDate = nil

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

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

    private static func teardown() {
        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
        labelField = nil
    }

    // MARK: - Timer

    private static func updateTimerLabel() {
        guard let callStartDate, let labelField else { return }
        let elapsed = Int(Date().timeIntervalSince(callStartDate))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let text = String(format: "%02d:%02d", minutes, seconds)

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        labelField.attributedStringValue = attributed
    }

    // MARK: - Animation

    /// A thin sliver path at the notch-touching (left) edge — the starting state for expand.
    private static func collapsedWingPath(wingHeight: CGFloat) -> CGPath {
        let tr = topCornerRadius
        let rect = CGRect(x: 0, y: 0, width: tr + 2, height: wingHeight)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr))
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - tr))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private static func animateExpand(
        shapeLayer: CAShapeLayer,
        label: NSTextField,
        wingHeight: CGFloat
    ) {
        let collapsedPath = collapsedWingPath(wingHeight: wingHeight)
        let expandedPath = rightWingPath(in: CGRect(x: 0, y: 0, width: wingWidth, height: wingHeight))

        // Start from collapsed.
        shapeLayer.path = collapsedPath

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
        let notchRightX = screenFrame.midX + notchSize.width / 2
        let originX = notchRightX - topCornerRadius - 8
        let originY = screenFrame.maxY - windowHeight
        panel.setFrame(NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight), display: true)
    }

    // MARK: - Wing Path

    /// Generates a path for the right wing shape — a horizontal mirror of `NotchCallButton.leftWingPath`.
    ///
    /// ```
    /// ┌──────────────  ← flat top at full width (flush with notch)
    /// ╲            ╱   ← top-left & top-right: inward quad curves (wing flare)
    ///  │          │    ← body: sides inset by topCornerRadius
    ///  ╱────────╯      ← bottom-right: outward curve, bottom-left: inward quad curve (wing flare)
    /// ┘                ← bottom at full width (flush with notch)
    /// ```
    private static func rightWingPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tr = topCornerRadius
        let br = bottomCornerRadius

        // Start at top-right corner (flat top edge).
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Top edge → left at full width (flush with notch).
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left: inward quad curve — flares from full width down to body.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        // Left side straight down (body is inset by tr from the notch edge).
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - tr))

        // Bottom-left: inward quad curve — body flares back out to full width.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // Bottom edge → right.
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // Bottom-right corner: outward curve.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )

        // Right side straight up to the top-right corner area.
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // Top-right corner: inward quad curve (matches notch curvature).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    // MARK: - Label

    private static func makeTimerLabel(text: String) -> NSTextField {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        let label = NSTextField(labelWithAttributedString: attributed)
        label.alignment = .center
        return label
    }
}

// MARK: - Flipped View

private final class FlippedCallTimerView: NSView {
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        return layer
    }
}
