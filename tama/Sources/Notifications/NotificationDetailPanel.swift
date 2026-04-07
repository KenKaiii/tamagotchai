import AppKit
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "notch"
)

/// A glassmorphic detail panel that displays the full content of a notification.
@MainActor
final class NotificationDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private static var activePanel: NotificationDetailPanel?

    /// Shows a detail panel centered on screen with the given title and body.
    static func show(title: String, body: String) {
        activePanel?.orderOut(nil)
        activePanel = nil

        let panel = NotificationDetailPanel(title: title, body: body)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        activePanel = panel
        logger.info("Showing notification detail panel")
    }

    private init(title notifTitle: String, body: String) {
        let panelWidth: CGFloat = 680
        let panelHeight: CGFloat = 420
        let cornerRadius: CGFloat = 28

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        // Clear wrapper so the window itself is fully transparent.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = wrapper

        // Glass background
        let effectView = NSVisualEffectView(frame: wrapper.bounds)
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(effectView)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])

        // Title label
        let titleLabel = NSTextField(labelWithString: notifTitle)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(titleLabel)

        // Close button — matches onboarding style
        let closeButton = CircleCloseButton()
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(closeButton)

        // Body text view in a scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let rendered = MarkdownRenderer.render(body)
        textView.textStorage?.setAttributedString(rendered)

        scrollView.documentView = textView
        effectView.addSubview(scrollView)

        let padding: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: padding + 8),
            titleLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.topAnchor.constraint(equalTo: effectView.topAnchor, constant: padding + 4),
            closeButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -padding),
        ])
    }

    @objc private func closeTapped() {
        ButtonSound.shared.play()
        orderOut(nil)
        Self.activePanel = nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            closeTapped()
            return
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        closeTapped()
    }
}
