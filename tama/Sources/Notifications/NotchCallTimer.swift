import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "calltimer"
)

/// The current mode of the call wing — controls waveform bar color.
enum CallWingMode {
    case listening
    case responding
}

/// A right-side wing extending from the hardware notch that shows a live audio waveform.
///
/// Mirrors `NotchCallButton` (left wing) but on the right side. Displays animated
/// waveform bars that react to audio level — green when listening, grey when responding.
/// Created/destroyed by `NotchCallButton` when the user starts/ends a call.
@MainActor
enum NotchCallTimer {
    // MARK: - State

    private static var panel: NSPanel?
    private static var isVisible = false
    private static var shapeLayer: CAShapeLayer?
    private static var barLayers: [CALayer] = []
    private static var displayLink: CVDisplayLink?
    private static var currentMode: CallWingMode = .listening
    private static var audioLevel: Double = 0
    private static var barHeights: [CGFloat] = []

    // MARK: - Constants

    /// Width of the wing extension.
    private static let wingWidth: CGFloat = 90

    /// Top corner radius on the right side (matches notch curvature).
    private static let topCornerRadius: CGFloat = 6

    /// Bottom corner radius (matching notch aesthetic).
    private static let bottomCornerRadius: CGFloat = 10

    private static let collapseDuration: TimeInterval = 0.25

    private static let barCount = 5
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3.5
    private static let barCornerRadius: CGFloat = 1.5
    private static let barMinHeight: CGFloat = 3

    // MARK: - Public API

    /// Show the waveform wing joined to the right side of the notch.
    static func show() {
        guard !isVisible else { return }
        guard let screen = NSScreen.main else { return }

        logger.info("Showing call waveform wing")
        isVisible = true
        audioLevel = 0
        barHeights = Array(repeating: barMinHeight, count: barCount)

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
        bridgeLayer.frame = CGRect(x: -1, y: 0, width: 2, height: wingHeight)
        rootView.layer?.addSublayer(bridgeLayer)

        // Waveform bars — centered in the wing body.
        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let barsStartX = topCornerRadius + (wingWidth - topCornerRadius * 2 - totalBarsWidth) / 2 + 6
        var bars: [CALayer] = []

        for i in 0 ..< barCount {
            let bar = CALayer()
            bar.backgroundColor = barColor(for: currentMode).cgColor
            bar.cornerRadius = barCornerRadius
            let x = barsStartX + CGFloat(i) * (barWidth + barSpacing)
            bar.frame = CGRect(
                x: x,
                y: (wingHeight - barMinHeight) / 2,
                width: barWidth,
                height: barMinHeight
            )
            bar.opacity = 0 // Start invisible for fade-in
            rootView.layer?.addSublayer(bar)
            bars.append(bar)
        }
        barLayers = bars

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        panel = newPanel
        shapeLayer = shape

        // Animate wing expanding from notch edge.
        animateExpand(shapeLayer: shape, wingHeight: wingHeight)

        // Fade in bars after expand.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            for bar in bars {
                bar.opacity = 1
            }
            CATransaction.commit()
        }

        // Start display link for smooth bar animation.
        startDisplayLink()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in reposition() }
        }
    }

    /// Hide and tear down the waveform wing with a collapse animation.
    static func hide() {
        guard isVisible else { return }
        logger.info("Hiding call waveform wing")
        isVisible = false

        stopDisplayLink()

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        guard let panel, let shapeLayer else {
            teardown()
            return
        }

        // Fade out bars immediately.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        for bar in barLayers {
            bar.opacity = 0
        }
        CATransaction.commit()

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
                MainActor.assumeIsolated { teardown() }
            }
        }
    }

    /// Update the audio level (0.0–1.0) for waveform animation.
    static func setAudioLevel(_ level: Double) {
        audioLevel = level
    }

    /// Switch between listening (green) and responding (grey) mode.
    static func setMode(_ mode: CallWingMode) {
        currentMode = mode
        let color = barColor(for: mode).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        for bar in barLayers {
            bar.backgroundColor = color
        }
        CATransaction.commit()
    }

    /// Temporarily hide the waveform panel while a notch overlay is active.
    static func hideForOverlay() {
        guard isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.opacity = 0
        }
        CATransaction.commit()
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    /// Restore the waveform panel after notch overlays clear, with expand animation.
    static func showAfterOverlay() {
        guard isVisible, let panel, let shapeLayer else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Re-run expand animation.
        let wingHeight = panel.frame.height
        animateExpand(shapeLayer: shapeLayer, wingHeight: wingHeight)

        // Fade bars back in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            for bar in barLayers {
                bar.opacity = 1
            }
            CATransaction.commit()
        }
    }

    // MARK: - Private

    private static func teardown() {
        stopDisplayLink()
        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
        barLayers = []
        barHeights = []
    }

    private static func barColor(for mode: CallWingMode) -> NSColor {
        switch mode {
        case .listening:
            NSColor.systemGreen
        case .responding:
            NSColor.white.withAlphaComponent(0.45)
        }
    }

    // MARK: - Display Link

    private static func startDisplayLink() {
        stopDisplayLink()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        CVDisplayLinkSetOutputHandler(link) { _, _, _, _, _ in
            DispatchQueue.main.async { updateBars() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    private static func stopDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
    }

    private static func updateBars() {
        guard isVisible, let panel else { return }
        let wingHeight = panel.frame.height
        let maxBarHeight = wingHeight - 8

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for i in 0 ..< barCount {
            let randomFactor = CGFloat.random(in: 0.3 ... 1.0)
            let targetHeight = max(barMinHeight, CGFloat(audioLevel) * maxBarHeight * randomFactor)
            barHeights[i] += (targetHeight - barHeights[i]) * 0.25

            let h = min(barHeights[i], maxBarHeight)
            var frame = barLayers[i].frame
            frame.size.height = h
            frame.origin.y = (wingHeight - h) / 2
            barLayers[i].frame = frame
        }

        CATransaction.commit()
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
        wingHeight: CGFloat
    ) {
        let collapsedPath = collapsedWingPath(wingHeight: wingHeight)
        let expandedPath = rightWingPath(in: CGRect(x: 0, y: 0, width: wingWidth, height: wingHeight))

        shapeLayer.path = collapsedPath

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
        panel.setFrame(
            NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
            display: true
        )
    }

    // MARK: - Wing Path

    private static func rightWingPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tr = topCornerRadius
        let br = bottomCornerRadius

        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        path.closeSubpath()
        return path
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
