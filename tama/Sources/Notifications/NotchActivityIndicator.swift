import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "activity"
)

/// Metadata for a tracked process shown in the activity indicator.
private struct ProcessInfo {
    let label: String
    var detail: String?
}

/// A persistent notch-hugging indicator that tracks all concurrent Tama processes.
///
/// Tracks the chat agent and background routines simultaneously. Shows a single
/// label when one process is active, or a count with the latest detail when
/// multiple processes run concurrently.
@MainActor
enum NotchActivityIndicator {
    // MARK: - State

    private static var panel: NSPanel?
    private static var shapeLayer: CAShapeLayer?
    private static var shimmerView: ShimmerTextView?
    private static var isVisible = false

    /// Active processes keyed by their ID.
    private static var processes: [String: ProcessInfo] = [:]

    /// The most recently updated process ID (for showing its detail in multi-process mode).
    private static var lastUpdatedID: String?

    // MARK: - Constants

    private static let closedTopRadius: CGFloat = 6
    private static let closedBottomRadius: CGFloat = 10
    private static let expandedTopRadius: CGFloat = 10
    private static let expandedBottomRadius: CGFloat = 14
    private static let shadowPadding: CGFloat = 16
    private static let expandDuration: TimeInterval = 0.4
    private static let collapseDuration: TimeInterval = 0.25

    // MARK: - Public API

    /// Register a new active process. Shows the indicator if not already visible.
    static func addProcess(id: String, label: String) {
        processes[id] = ProcessInfo(label: label)
        lastUpdatedID = id
        logger.info("Activity add process '\(id)': '\(label)' (total: \(processes.count))")

        if isVisible {
            refreshDisplayText()
        } else {
            showIndicator()
        }
    }

    /// Remove a process by ID. Hides the indicator when no processes remain.
    static func removeProcess(id: String) {
        guard processes.removeValue(forKey: id) != nil else { return }
        logger.info("Activity remove process '\(id)' (remaining: \(processes.count))")

        if processes.isEmpty {
            hide()
        } else {
            if lastUpdatedID == id {
                lastUpdatedID = processes.keys.first
            }
            refreshDisplayText()
        }
    }

    /// Update transient detail text for a specific process (e.g. tool name).
    static func updateDetail(id: String, text: String) {
        guard processes[id] != nil else { return }
        processes[id]?.detail = text
        lastUpdatedID = id
        refreshDisplayText()
    }

    // MARK: - Display Text

    /// Computes and applies the current display string based on active processes.
    private static func refreshDisplayText() {
        guard isVisible, let shimmerView else { return }

        let count = processes.count
        if count == 1, let only = processes.values.first {
            shimmerView.text = only.detail ?? only.label
        } else if count > 1 {
            let latestDetail = lastUpdatedID.flatMap { processes[$0]?.detail }
            if let detail = latestDetail {
                shimmerView.text = "(\(count)) \(detail)"
            } else {
                shimmerView.text = "(\(count)) Tama processes active"
            }
        }
    }

    // MARK: - Show / Hide

    private static func showIndicator() {
        guard !isVisible else { return }
        guard let screen = NSScreen.main else { return }
        NotchOverlayTracker.overlayDidShow()

        let displayText: String = {
            let count = processes.count
            if count == 1, let only = processes.values.first {
                return only.detail ?? only.label
            } else if count > 1 {
                return "(\(count)) Tama processes active"
            }
            return "Thinking…"
        }()

        logger.info("Showing activity indicator: '\(displayText)'")
        isVisible = true

        let notchSize = screen.notchSize
        let screenFrame = screen.frame

        // When a call is active, span the full width from the left call button
        // to the right waveform wing so the indicator covers both wings.
        let callButtonWidth: CGFloat = 120
        let callTimerWidth: CGFloat = 90
        let expandedWidth: CGFloat = if NotchCallButton.isInCall {
            notchSize.width + callButtonWidth + callTimerWidth
        } else {
            notchSize.width + 120
        }
        let expandedHeight = notchSize.height + 36

        let windowWidth = expandedWidth + shadowPadding * 2
        let windowHeight = expandedHeight + shadowPadding

        let originX = screenFrame.midX - windowWidth / 2
        let originY = screenFrame.maxY - windowHeight

        let newPanel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .mainMenu + 3
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.appearance = NSAppearance(named: .darkAqua)

        // Flipped root view (y=0 at top) — same pattern as NotchNotificationPresenter.
        let rootView = FlippedActivityView(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        )
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        // Shape layer: black notch silhouette.
        let shape = CAShapeLayer()
        shape.fillColor = NSColor.black.cgColor

        let closedRect = closedNotchRect(
            windowSize: NSSize(width: windowWidth, height: windowHeight),
            notchSize: notchSize
        )
        shape.path = NotchShapePath.path(
            in: closedRect,
            topCornerRadius: closedTopRadius,
            bottomCornerRadius: closedBottomRadius
        )
        shape.frame = rootView.bounds
        rootView.layer?.addSublayer(shape)

        // 1px bridge to eliminate subpixel gap with hardware notch.
        let bridgeLayer = CALayer()
        bridgeLayer.backgroundColor = NSColor.black.cgColor
        bridgeLayer.frame = CGRect(
            x: closedRect.origin.x + closedTopRadius,
            y: 0,
            width: closedRect.width - closedTopRadius * 2,
            height: 1
        )
        rootView.layer?.addSublayer(bridgeLayer)

        // Shadow (visible when expanded).
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 8
        shape.shadowOffset = CGSize(width: 0, height: 3)

        // Shimmer text view positioned below the notch area.
        let expandedRect = expandedNotchRect(
            windowSize: NSSize(width: windowWidth, height: windowHeight)
        )
        let textWidth = expandedRect.width - 24
        let textHeight: CGFloat = 16
        let shimText = ShimmerTextView(
            frame: NSRect(
                x: (windowWidth - textWidth) / 2,
                y: notchSize.height + 6,
                width: textWidth,
                height: textHeight
            ),
            initialText: displayText
        )
        shimText.alphaValue = 0
        rootView.addSubview(shimText)

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        // Store references.
        panel = newPanel
        shapeLayer = shape
        shimmerView = shimText

        // Animate expand from notch.
        animateExpand(
            shapeLayer: shape,
            shimmerView: shimText,
            windowSize: NSSize(width: windowWidth, height: windowHeight)
        )
    }

    /// Hide the activity indicator with a collapse animation.
    private static func hide() {
        guard isVisible else { return }
        logger.info("Hiding activity indicator")
        isVisible = false
        NotchOverlayTracker.overlayDidHide()
        processes.removeAll()
        lastUpdatedID = nil

        guard let panel, let shapeLayer, let screen = NSScreen.main else {
            teardown()
            return
        }

        // Stop shimmer.
        shimmerView?.stopShimmer()

        // Fade out text immediately.
        if let shimmerView {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                shimmerView.animator().alphaValue = 0
            }
        }

        // Collapse shape back to notch size.
        let windowSize = panel.frame.size
        let notchSize = screen.notchSize
        let closedRect = closedNotchRect(windowSize: windowSize, notchSize: notchSize)
        let closedPath = NotchShapePath.path(
            in: closedRect,
            topCornerRadius: closedTopRadius,
            bottomCornerRadius: closedBottomRadius
        )

        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = shapeLayer.path
        pathAnimation.toValue = closedPath
        pathAnimation.damping = 18
        pathAnimation.stiffness = 220
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "collapsePath")
        shapeLayer.path = closedPath

        // Remove shadow.
        let shadowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnimation.fromValue = shapeLayer.shadowOpacity
        shadowAnimation.toValue = Float(0)
        shadowAnimation.duration = collapseDuration
        shadowAnimation.isRemovedOnCompletion = false
        shadowAnimation.fillMode = .forwards
        shapeLayer.add(shadowAnimation, forKey: "shadowOut")
        shapeLayer.shadowOpacity = 0

        // After collapse, fade out and remove window.
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

    // MARK: - Private

    private static func teardown() {
        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
        shimmerView = nil
    }

    private static func closedNotchRect(windowSize: NSSize, notchSize: NSSize) -> CGRect {
        let x = (windowSize.width - notchSize.width) / 2
        return CGRect(x: x, y: 0, width: notchSize.width, height: notchSize.height)
    }

    private static func expandedNotchRect(windowSize: NSSize) -> CGRect {
        let x = shadowPadding
        let width = windowSize.width - shadowPadding * 2
        let height = windowSize.height - shadowPadding
        return CGRect(x: x, y: 0, width: width, height: height)
    }

    private static func animateExpand(
        shapeLayer: CAShapeLayer,
        shimmerView: ShimmerTextView,
        windowSize: NSSize
    ) {
        let expandedRect = expandedNotchRect(windowSize: windowSize)
        let expandedPath = NotchShapePath.path(
            in: expandedRect,
            topCornerRadius: expandedTopRadius,
            bottomCornerRadius: expandedBottomRadius
        )

        // Animate shape path.
        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = shapeLayer.path
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

        // Animate shadow appearing.
        let shadowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnimation.fromValue = 0
        shadowAnimation.toValue = Float(0.4)
        shadowAnimation.duration = expandDuration
        shadowAnimation.isRemovedOnCompletion = false
        shadowAnimation.fillMode = .forwards
        shapeLayer.add(shadowAnimation, forKey: "shadowIn")
        shapeLayer.shadowOpacity = 0.4

        // Fade in shimmer text after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shimmerView.animator().alphaValue = 1.0
            }
            shimmerView.startShimmer()
        }
    }
}

// MARK: - Shimmer Text View

/// Renders text with a sweeping shimmer highlight that follows the letter shapes.
///
/// Uses a `CAGradientLayer` masked by a `CATextLayer` so the shimmer gradient
/// is only visible through the text glyphs — giving the appearance that the
/// text itself is shimmering.
final class ShimmerTextView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let textMaskLayer = CATextLayer()

    /// The base (non-shimmer) text color.
    private let baseColor = NSColor.white.withAlphaComponent(0.7)

    /// The bright highlight color in the shimmer sweep.
    private let highlightColor = NSColor.white

    /// The font used for the text.
    private let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Update the displayed text.
    var text: String = "" {
        didSet {
            textMaskLayer.string = text
            // Resize mask to match the view bounds (text is centered).
            textMaskLayer.frame = bounds
        }
    }

    init(frame: NSRect, initialText: String) {
        text = initialText
        super.init(frame: frame)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        textMaskLayer.frame = bounds
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true

        // Text mask layer — the gradient is only visible where the text is.
        textMaskLayer.string = text
        textMaskLayer.font = textFont
        textMaskLayer.fontSize = textFont.pointSize
        textMaskLayer.foregroundColor = NSColor.white.cgColor
        textMaskLayer.alignmentMode = .center
        textMaskLayer.truncationMode = .end
        textMaskLayer.isWrapped = false
        textMaskLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        textMaskLayer.frame = bounds

        // Gradient layer — horizontal sweep from base → highlight → base.
        gradientLayer.colors = [
            baseColor.cgColor,
            highlightColor.cgColor,
            baseColor.cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.locations = [0, 0.5, 1].map { NSNumber(value: $0) }
        gradientLayer.frame = bounds
        gradientLayer.mask = textMaskLayer

        layer?.addSublayer(gradientLayer)
    }

    func startShimmer() {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0].map { NSNumber(value: $0) }
        animation.toValue = [1.0, 1.5, 2.0].map { NSNumber(value: $0) }
        animation.duration = 1.5
        animation.repeatCount = .infinity
        gradientLayer.add(animation, forKey: "shimmer")
    }

    func stopShimmer() {
        gradientLayer.removeAnimation(forKey: "shimmer")
    }
}

// MARK: - Flipped View for Activity Indicator

/// An `NSView` with flipped geometry so y=0 is at the top (matching screen top / notch position).
private final class FlippedActivityView: NSView {
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        return layer
    }
}
