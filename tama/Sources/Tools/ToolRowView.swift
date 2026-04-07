import AppKit

/// A single row in the tool list showing icon, name, description, and optional shortcut hint.
/// For `TogglePanelTool` instances, displays an inline toggle switch instead of a drilldown arrow.
final class ToolRowView: NSView {
    var onSelect: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var toggleView: PillToggleView?
    private weak var toggleTool: (any TogglePanelTool)?

    private lazy var highlightLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer.cornerRadius = 6
        layer.isHidden = true
        return layer
    }()

    init(tool: PanelTool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlightLayer)
        setupViews(tool: tool)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews(tool: PanelTool) {
        let iconSize: CGFloat = 28
        let iconView = NSImageView(image: MenuBarIcon.symbolIcon(name: tool.icon, size: iconSize))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: tool.name)
        nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: tool.toolDescription)
        descLabel.font = .systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [nameLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Toggle tools get a custom pill toggle; regular tools get a shortcut hint
        if let toggle = tool as? (any TogglePanelTool) {
            toggleTool = toggle
            let pill = PillToggleView(isOn: toggle.isEnabled)
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
            toggleView = pill

            NSLayoutConstraint.activate([
                pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                pill.centerYAnchor.constraint(equalTo: centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -12),
            ])

            // Listen for external state changes
            toggle.onStateChanged = { [weak self] in
                guard let toggle = self?.toggleTool else { return }
                self?.toggleView?.setOn(toggle.isEnabled, animated: true)
            }
        } else {
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -20
            ).isActive = true

            if let hint = tool.shortcutHint {
                let hintLabel = NSTextField(labelWithString: hint)
                hintLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                hintLabel.textColor = .tertiaryLabelColor
                hintLabel.translatesAutoresizingMaskIntoConstraints = false
                hintLabel.setContentHuggingPriority(.required, for: .horizontal)
                addSubview(hintLabel)

                NSLayoutConstraint.activate([
                    hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                    hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
                textStack.trailingAnchor.constraint(
                    lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -12
                ).isActive = true
            }
        }
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds.insetBy(dx: 8, dy: 1)
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
        isHovered = true
        highlightLayer.isHidden = false
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        highlightLayer.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        // For toggle tools, clicking the row toggles
        if toggleTool != nil {
            ButtonSound.shared.play()
            toggleTool?.toggle()
            if let isOn = toggleTool?.isEnabled {
                toggleView?.setOn(isOn, animated: true)
            }
            return
        }
        ButtonSound.shared.play()
        super.mouseDown(with: event)
        onSelect?()
    }
}

// MARK: - Custom Pill Toggle

/// A custom iOS-style pill toggle with green on-state background.
/// Larger and more visually prominent than the default NSSwitch.
private final class PillToggleView: NSView {
    private static let pillWidth: CGFloat = 40
    private static let pillHeight: CGFloat = 24
    private static let knobInset: CGFloat = 2
    private static let knobSize: CGFloat = pillHeight - knobInset * 2

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    private(set) var isOn: Bool

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.pillHeight))
        wantsLayer = true
        setupLayers()
        updateAppearance(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.pillWidth, height: Self.pillHeight)
    }

    private func setupLayers() {
        // Track (background pill)
        trackLayer.cornerRadius = Self.pillHeight / 2
        trackLayer.frame = NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.pillHeight)
        layer?.addSublayer(trackLayer)

        // Knob (circle)
        knobLayer.cornerRadius = Self.knobSize / 2
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.2
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        knobLayer.shadowRadius = 2
        layer?.addSublayer(knobLayer)
    }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        updateAppearance(animated: animated)
    }

    private func updateAppearance(animated: Bool) {
        let onColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
        let offColor = NSColor.white.withAlphaComponent(0.15).cgColor
        let knobX = isOn
            ? Self.pillWidth - Self.knobSize - Self.knobInset
            : Self.knobInset
        let knobFrame = NSRect(x: knobX, y: Self.knobInset, width: Self.knobSize, height: Self.knobSize)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                trackLayer.backgroundColor = isOn ? onColor : offColor
                knobLayer.frame = knobFrame
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trackLayer.backgroundColor = isOn ? onColor : offColor
            knobLayer.frame = knobFrame
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        trackLayer.frame = bounds
    }
}
