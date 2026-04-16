import AppKit
import Foundation
import QuartzCore

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

    // MARK: - Config

    /// Logical size (in points) of the cursor glyph.
    private static let cursorSize: CGFloat = 32
    /// Outline padding around the cursor for the white halo.
    private static let outlinePadding: CGFloat = 2
    /// Offset from the target to where the cursor tip is drawn. The arrow
    /// tip (top-left of the image) lands *on* the target, so the visible
    /// body extends down-and-right from the point.
    private static let tipOffset = CGPoint(x: 0, y: 0)

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

        let root = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        root.wantsLayer = true
        root.layer = CALayer()
        root.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = root

        configureLayers()
        root.addSubview(labelView)
    }

    // MARK: - Public

    /// Move the panel to cover a new screen frame (handles resolution changes).
    func syncFrame(to screenFrame: NSRect) {
        guard frame != screenFrame else { return }
        setFrame(screenFrame, display: false)
        contentView?.frame = NSRect(origin: .zero, size: screenFrame.size)
    }

    /// Fade the cursor in at `point` (in global screen coordinates). If a
    /// pulse is requested, schedules the ripple after the fade-in.
    func showCursor(at point: CGPoint, label: String?, pulse: Bool) {
        orderFrontRegardless()

        let local = toLocal(point)
        // Commit the cursor position without animating the move — only the
        // opacity animates on first show.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = local
        outlineLayer.position = local
        pulseLayer.position = local
        CATransaction.commit()

        updateLabel(label, at: local)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        cursorLayer.opacity = 1
        outlineLayer.opacity = 1
        cursorLayer.add(fade, forKey: "fadeIn")
        outlineLayer.add(fade, forKey: "fadeIn")

        isCursorVisible = true

        if pulse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pulseAtCurrentPosition()
                }
            }
        }
    }

    /// Animate the cursor from its current displayed position to `point`.
    func moveCursor(
        to point: CGPoint,
        duration: TimeInterval,
        label: String?,
        pulse: Bool
    ) {
        let local = toLocal(point)
        let current = cursorLayer.presentation()?.position ?? cursorLayer.position

        // Cancel any in-flight move so the next animation starts from the
        // actual displayed position.
        cursorLayer.removeAnimation(forKey: "move")
        outlineLayer.removeAnimation(forKey: "move")
        pulseLayer.removeAnimation(forKey: "move")

        let easing = CAMediaTimingFunction(name: .easeInEaseOut)

        for layer in [cursorLayer, outlineLayer, pulseLayer] {
            let anim = CABasicAnimation(keyPath: "position")
            anim.fromValue = NSValue(point: current)
            anim.toValue = NSValue(point: local)
            anim.duration = duration
            anim.timingFunction = easing
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "move")
            layer.position = local
        }

        updateLabel(label, at: local, animateDuration: duration)

        if pulse {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pulseAtCurrentPosition()
                }
            }
        }
    }

    /// Fade the cursor out over `duration`. Does not close the panel.
    func fadeOutCursor(duration: TimeInterval) {
        guard isCursorVisible else { return }
        isCursorVisible = false

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        cursorLayer.opacity = 0
        outlineLayer.opacity = 0
        cursorLayer.add(fade, forKey: "fadeOut")
        outlineLayer.add(fade, forKey: "fadeOut")

        labelView.fadeOut(duration: duration)
    }

    /// Trigger a ripple at the cursor's current displayed position.
    func pulseAtCurrentPosition() {
        guard isCursorVisible else { return }
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

    // MARK: - NSPanel Overrides

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Private

    private func configureLayers() {
        guard let rootLayer = contentView?.layer else { return }

        // Outline (white halo) — slightly larger than the cursor, sits behind.
        let outlineSize = Self.cursorSize + Self.outlinePadding * 2
        outlineLayer.bounds = CGRect(x: 0, y: 0, width: outlineSize, height: outlineSize)
        outlineLayer.contents = tintedCursorImage(color: .white)
        outlineLayer.contentsGravity = .resizeAspect
        outlineLayer.opacity = 0
        outlineLayer.anchorPoint = anchorForArrowTip()
        outlineLayer.shadowColor = NSColor.black.cgColor
        outlineLayer.shadowOpacity = 0.35
        outlineLayer.shadowOffset = CGSize(width: 0, height: -1)
        outlineLayer.shadowRadius = 3
        rootLayer.addSublayer(outlineLayer)

        // Cursor glyph — real macOS arrow tinted Tama orange at 70% opacity.
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: Self.cursorSize, height: Self.cursorSize)
        cursorLayer.contents = tintedCursorImage(color: NSColor.systemOrange.withAlphaComponent(0.9))
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.opacity = 0
        cursorLayer.anchorPoint = anchorForArrowTip()
        rootLayer.addSublayer(cursorLayer)

        // Pulse ring.
        pulseLayer.fillColor = NSColor.clear.cgColor
        pulseLayer.strokeColor = NSColor.systemOrange.cgColor
        pulseLayer.lineWidth = 3
        pulseLayer.opacity = 0
        rootLayer.addSublayer(pulseLayer)
    }

    /// Anchor point so the "tip" of the arrow (top-left corner of the glyph)
    /// sits at the layer's `position`. `NSCursor.arrow.hotSpot` is at roughly
    /// (4, 4) out of a ~24pt image — we approximate by anchoring near the
    /// top-left. Values are in unit coordinates (0..1).
    private func anchorForArrowTip() -> CGPoint {
        // ~1/8 in from each edge aligns with the arrow's visible tip.
        CGPoint(x: 0.15, y: 0.85)
    }

    /// Build a tinted version of `NSCursor.arrow.image` for use as a layer's
    /// `contents`. We render the system arrow through a colour fill so the
    /// virtual cursor has a distinct Tama-brand tint but still reads as a
    /// cursor.
    private func tintedCursorImage(color: NSColor) -> CGImage? {
        let source = NSCursor.arrow.image
        let size = NSSize(width: Self.cursorSize, height: Self.cursorSize)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        var proposedRect = NSRect(origin: .zero, size: size)
        return tinted.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
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
