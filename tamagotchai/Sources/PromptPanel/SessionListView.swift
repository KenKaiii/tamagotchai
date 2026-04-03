import AppKit

/// Displays grouped chat sessions in a scrollable list below the input field.
final class SessionListView: NSView {
    /// Called when a session is clicked.
    var onSelectSession: ((ChatSession) -> Void)?

    /// Called when a session's delete button is clicked.
    var onDeleteSession: ((ChatSession) -> Void)?

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

    /// Current tracking areas for hover effects.
    private var rowTrackingAreas: [(area: NSTrackingArea, view: NSView)] = []

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

        let docView = NSView()
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

    /// Reloads the session list with grouped data.
    func reload(groups: [(label: String, sessions: [ChatSession])]) {
        // Remove old views and tracking areas
        for (area, view) in rowTrackingAreas {
            view.removeTrackingArea(area)
        }
        rowTrackingAreas.removeAll()
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for group in groups {
            contentStack.addArrangedSubview(makeSectionHeader(group.label))
            for session in group.sessions {
                let row = makeSessionRow(session)
                contentStack.addArrangedSubview(row)
            }
        }

        // Ensure scroll position starts at the top
        scrollView.documentView?.scroll(.zero)
    }

    // MARK: - Row Construction

    private func makeSectionHeader(_ title: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    private func makeSessionRow(_ session: ChatSession) -> NSView {
        let row = SessionRowView(session: session)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.onSelect = { [weak self] in
            self?.onSelectSession?(session)
        }
        row.onDelete = { [weak self] in
            self?.onDeleteSession?(session)
        }
        return row
    }
}

// MARK: - Session Row View

/// A single session row with hover highlight, delete button, and click handling.
private final class SessionRowView: NSView {
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    private let session: ChatSession
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

        // Add tracking area for hover effect on the button itself
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: btn,
            userInfo: ["isDeleteButton": true]
        )
        btn.addTrackingArea(area)

        return btn
    }()

    private lazy var deleteButtonHoverTracker: DeleteButtonHoverTracker = {
        let tracker = DeleteButtonHoverTracker(button: deleteButton)
        return tracker
    }()

    private let timeLabel = NSTextField(labelWithString: "")

    init(session: ChatSession) {
        self.session = session
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
        let mood = MenuBarMood.Mood(rawValue: session.moodIcon) ?? .afternoon
        let iconSize: CGFloat = 28
        let iconImage = MenuBarIcon.sessionIcon(mood: mood, size: iconSize)
        let iconView = NSImageView(image: iconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: session.title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.stringValue = Self.relativeTime(session.updatedAt)
        timeLabel.font = .systemFont(ofSize: 22, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(timeLabel)
        addSubview(deleteButton)

        // Size the delete button with padding
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 56),
            deleteButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Set up hover tracking on delete button
        _ = deleteButtonHoverTracker
    }

    @objc private func deleteClicked() {
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
        timeLabel.isHidden = true
        deleteButton.isHidden = false
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        highlightLayer.isHidden = true
        deleteButton.isHidden = true
        timeLabel.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        // Don't trigger select if clicking the delete button
        let loc = convert(event.locationInWindow, from: nil)
        if deleteButton.frame.contains(loc) { return }
        super.mouseDown(with: event)
        onSelect?()
    }

    private static func relativeTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }

        let components = calendar.dateComponents([.day], from: date, to: now)
        if let days = components.day, days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

// MARK: - Delete Button Hover Tracker

/// Tracks mouse enter/exit on the delete button to adjust its background opacity.
private final class DeleteButtonHoverTracker: NSResponder {
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
