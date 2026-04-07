import AppKit

/// NSTextBlock subclass that draws a tinted rounded-rect background with a subtle border.
final class ErrorTextBlock: NSTextBlock {
    private let tint: NSColor

    init(tint: NSColor) {
        self.tint = tint
        super.init()
        setContentWidth(100, type: .percentageValueType)
        setWidth(12, type: .absoluteValueType, for: .padding)
        setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView?,
        characterRange _: NSRange,
        layoutManager _: NSLayoutManager
    ) {
        let rect = frameRect.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)

        // Tinted fill — higher opacity for visibility on dark backgrounds
        tint.withAlphaComponent(0.55).setFill()
        path.fill()

        // Border
        tint.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
