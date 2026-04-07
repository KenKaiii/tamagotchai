import AppKit

/// A circular close button matching the onboarding design — small "xmark" icon
/// in a 22×22 translucent white circle with hover brightening.
final class CircleCloseButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(config)
        imagePosition = .imageOnly
        contentTintColor = .white.withAlphaComponent(0.5)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        contentTintColor = .white.withAlphaComponent(0.8)
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with _: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        contentTintColor = .white.withAlphaComponent(0.5)
        NSCursor.pop()
    }
}
