import AppKit

/// The active tab filter for the session list.
enum SessionTab: Int {
    case chats = 0
    case reminders = 1
    case routines = 2
    case tasks = 3
    case skills = 4
    case tools = 5
}

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
        sv.contentView.postsBoundsChangedNotifications = true
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

    /// Scroll notification observer.
    private var scrollObserver: NSObjectProtocol?

    /// Session IDs that currently have an active agent task running.
    private var activeSessionIDs: Set<UUID> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates hover states on all row views after scrolling.
    /// When scrolling, the mouse stays stationary while content moves,
    /// so tracking areas don't automatically fire enter/exit events.
    private func updateHoverStatesAfterScroll() {
        let mouseLocation = window?.mouseLocationOutsideOfEventStream ?? .zero
        for case let row as SessionRowView in contentStack.arrangedSubviews {
            let rowLocation = row.convert(mouseLocation, from: nil)
            let isActuallyHovered = row.bounds.contains(rowLocation)
            row.updateHoverState(isHovered: isActuallyHovered)
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateHoverStatesAfterScroll()
        }

        let docView = FlippedDocumentView()
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

    /// Reloads the session list with grouped data, or shows an empty state message.
    func reload(
        groups: [(label: String, sessions: [ChatSession])],
        emptyMessage: String? = nil,
        activeSessionIDs: Set<UUID> = []
    ) {
        self.activeSessionIDs = activeSessionIDs
        // Remove old views and tracking areas
        for (area, view) in rowTrackingAreas {
            view.removeTrackingArea(area)
        }
        rowTrackingAreas.removeAll()
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if groups.isEmpty, let emptyMessage {
            contentStack.addArrangedSubview(makeEmptyState(emptyMessage))
        } else {
            for group in groups {
                contentStack.addArrangedSubview(makeSectionHeader(group.label))
                for session in group.sessions {
                    let row = makeSessionRow(session)
                    contentStack.addArrangedSubview(row)
                }
            }
        }
    }

    /// Resets scroll position to show the very first item (including section headers).
    func scrollToTop() {
        contentStack.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Row Construction

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
        let isActive = activeSessionIDs.contains(session.id)
        let row = SessionRowView(session: session, isActive: isActive)
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
    private let isActive: Bool
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
    private var titleLabel: NSTextField?

    private lazy var shimmerLayer: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.systemGreen.withAlphaComponent(0.0).cgColor,
            NSColor.systemGreen.withAlphaComponent(0.35).cgColor,
            NSColor.systemGreen.withAlphaComponent(0.0).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [-1, -0.5, 0].map { NSNumber(value: $0) }
        return gradient
    }()

    init(session: ChatSession, isActive: Bool = false) {
        self.session = session
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlightLayer)
        setupViews()
        if isActive {
            setupShimmer()
        }
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
        titleLabel.textColor = isActive ? .systemGreen : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel = titleLabel

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
        ButtonSound.shared.play()
        onDelete?()
    }

    private func setupShimmer() {
        guard let titleLabel else { return }
        titleLabel.wantsLayer = true
        titleLabel.layer?.addSublayer(shimmerLayer)
        titleLabel.layer?.masksToBounds = true

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0].map { NSNumber(value: $0) }
        animation.toValue = [1.0, 1.5, 2.0].map { NSNumber(value: $0) }
        animation.duration = 1.5
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "shimmer")
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds.insetBy(dx: 8, dy: 1)
        if isActive, let titleLabel {
            shimmerLayer.frame = titleLabel.bounds
        }
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

    /// Updates the hover state programmatically (used during scrolling).
    func updateHoverState(isHovered: Bool) {
        guard self.isHovered != isHovered else { return }
        self.isHovered = isHovered
        highlightLayer.isHidden = !isHovered
        deleteButton.isHidden = !isHovered
        timeLabel.isHidden = isHovered
    }

    override func mouseDown(with event: NSEvent) {
        // Don't trigger select if clicking the delete button
        let loc = convert(event.locationInWindow, from: nil)
        if deleteButton.frame.contains(loc) { return }
        ButtonSound.shared.play()
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

// MARK: - Flipped Document View

/// An NSView with a flipped coordinate system (origin at top-left)
/// so that scroll views display content from the top down.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
