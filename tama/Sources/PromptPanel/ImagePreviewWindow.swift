import AppKit

/// A glassmorphic detail panel that displays an image preview, matching the
/// notification detail modal style (rounded glass background, title bar, close button).
/// Sizes itself to fit the image exactly.
@MainActor
final class ImagePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var onDismiss: (() -> Void)?

    private static let maxPanelWidth: CGFloat = 960
    private static let maxPanelHeight: CGFloat = 780
    private static let minPanelWidth: CGFloat = 320
    private static let cornerRadius: CGFloat = 28
    private static let padding: CGFloat = 20
    private static let titleBarHeight: CGFloat = 52

    init(image: NSImage, title: String = "Image Preview") {
        let pad = Self.padding
        let titleH = Self.titleBarHeight

        // Use the pixel dimensions from the bitmap rep if available,
        // falling back to image.size. This avoids DPI scaling confusion.
        let pixelSize = if let rep = image.representations.first {
            NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            image.size
        }

        // On retina screens the image pixels map 2:1 to points.
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pointWidth = pixelSize.width / backingScale
        let pointHeight = pixelSize.height / backingScale

        // Panel width = image point width + padding, clamped.
        let panelWidth = min(
            Self.maxPanelWidth,
            max(Self.minPanelWidth, pointWidth + pad * 2)
        )

        // Scale image height to fit within the available width.
        let imageAreaWidth = panelWidth - pad * 2
        let displayScale = min(1.0, imageAreaWidth / pointWidth)
        let displayHeight = pointHeight * displayScale
        let displayWidth = pointWidth * displayScale

        // Panel height = title bar + image + bottom padding, clamped.
        let panelHeight = min(
            Self.maxPanelHeight,
            titleH + displayHeight + pad
        )

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating + 2
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        // Transparent wrapper
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
        effectView.layer?.cornerRadius = Self.cornerRadius
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
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(titleLabel)

        // Close button
        let closeButton = CircleCloseButton()
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(closeButton)

        // Image view — fixed size, centered horizontally
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(imageView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: pad + 8),
            titleLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12
            ),

            closeButton.topAnchor.constraint(equalTo: effectView.topAnchor, constant: pad + 4),
            closeButton.trailingAnchor.constraint(
                equalTo: effectView.trailingAnchor, constant: -pad
            ),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            imageView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            imageView.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: displayWidth),
            imageView.heightAnchor.constraint(equalToConstant: displayHeight),
        ])
    }

    @objc private func closeTapped() {
        ButtonSound.shared.play()
        orderOut(nil)
        onDismiss?()
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
