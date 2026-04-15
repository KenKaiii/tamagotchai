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

    /// Callback invoked when the button is clicked.
    static var onCallTapped: (() -> Void)?

    // MARK: - Constants

    /// Width of the wing extension.
    private static let wingWidth: CGFloat = 120

    /// Top corner radius on the left side (matches notch curvature).
    private static let topCornerRadius: CGFloat = 6

    /// Bottom corner radius (matching notch aesthetic).
    private static let bottomCornerRadius: CGFloat = 10

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
        rootView.addSubview(label)

        // Click overlay.
        let overlay = CallButtonOverlay(frame: rootView.bounds)
        overlay.autoresizingMask = [.width, .height]
        rootView.addSubview(overlay)

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        panel = newPanel
        shapeLayer = shape
        hoverLayer = hover

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

    /// Hide and tear down the call button.
    static func hide() {
        guard isVisible else { return }
        logger.info("Hiding call button")
        isVisible = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
        hoverLayer = nil
    }

    /// Called when the button is tapped.
    fileprivate static func handleTap() {
        ButtonSound.shared.play()
        logger.info("Call button tapped")
        onCallTapped?()
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
