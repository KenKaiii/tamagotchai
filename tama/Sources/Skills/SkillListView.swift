import AppKit

/// Displays a filterable list of skills in the Skills tab.
/// Matches the ToolListView styling with icon, name, and description rows.
final class SkillListView: NSView {
    /// Called when the user clicks a skill row.
    var onSelectSkill: ((Skill) -> Void)?

    /// Called when the user deletes a skill.
    var onDeleteSkill: ((Skill) -> Void)?

    private lazy var scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.scrollerStyle = .overlay
        sv.verticalScrollElasticity = .none
        return sv
    }()

    private lazy var contentStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        return stack
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let docView = SkillFlippedDocumentView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView
        docView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: docView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    /// Reloads the skill list with the given skills.
    func reload(skills: [Skill]) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if skills.isEmpty {
            contentStack.addArrangedSubview(makeEmptyState("No skills found."))
        } else {
            for skill in skills {
                let row = SkillRowView(skill: skill)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 52).isActive = true
                // Constrain row width to contentStack to prevent expansion from long descriptions
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
                row.onSelect = { [weak self] in
                    self?.onSelectSkill?(skill)
                }
                row.onDelete = { [weak self] in
                    self?.onDeleteSkill?(skill)
                }
                contentStack.addArrangedSubview(row)
            }
        }
    }

    /// The total content height for sizing the panel.
    var contentHeight: CGFloat {
        let rowHeight: CGFloat = 52
        let padding: CGFloat = 12
        let rows = contentStack.arrangedSubviews.count
        return CGFloat(rows) * rowHeight + padding
    }

    /// Resets scroll position to the top.
    func scrollToTop() {
        contentStack.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeEmptyState(_ message: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 80),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])

        return container
    }
}

// MARK: - Skill Row View

/// A single row in the skill list showing icon, name, and description.
/// Styled like ToolRowView for consistency.
private final class SkillRowView: NSView {
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    private lazy var highlightLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer.cornerRadius = 6
        layer.isHidden = true
        return layer
    }()

    private lazy var deleteButton: NSButton = {
        let btn = NSButton()
        btn.title = "Delete"
        btn.font = .systemFont(ofSize: 11, weight: .medium)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
        btn.layer?.borderWidth = 0.5
        btn.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        btn.contentTintColor = .systemRed
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        btn.target = self
        btn.action = #selector(deleteClicked)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        return btn
    }()

    private lazy var deleteButtonHoverTracker: SkillDeleteButtonHoverTracker = .init(button: deleteButton)

    private let skill: Skill

    init(skill: Skill) {
        self.skill = skill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlightLayer)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        let iconSize: CGFloat = 28
        let iconView = NSImageView(image: MenuBarIcon.symbolIcon(name: "bolt.fill", size: iconSize))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: skill.name)
        nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: skill.description)
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
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 56),
            deleteButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Constrain to delete button when visible, or to row edge when hidden
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        _ = deleteButtonHoverTracker
    }

    @objc private func deleteClicked() {
        ButtonSound.shared.play()
        onDelete?()
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
        deleteButton.isHidden = false
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        highlightLayer.isHidden = true
        deleteButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if deleteButton.frame.contains(loc) { return }
        ButtonSound.shared.play()
        super.mouseDown(with: event)
        onSelect?()
    }
}

// MARK: - Delete Button Hover Tracker

/// Tracks mouse enter/exit on the delete button to adjust its background opacity.
private final class SkillDeleteButtonHoverTracker: NSResponder {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
        super.init()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseEntered(with _: NSEvent) {
        button?.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
    }

    override func mouseExited(with _: NSEvent) {
        button?.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
    }
}

// MARK: - Flipped Document View

/// An NSView with a flipped coordinate system for top-down scroll content.
private final class SkillFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
