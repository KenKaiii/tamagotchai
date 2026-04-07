import AppKit

/// Displays grouped task lists in a scrollable list, matching the SessionListView pattern.
final class TaskListView: NSView {
    /// Called when a task list is clicked.
    var onSelectTaskList: ((TaskList) -> Void)?

    /// Called when a task list's delete button is clicked.
    var onDeleteTaskList: ((TaskList) -> Void)?

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

        let docView = TaskFlippedDocumentView()
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

    /// Reloads the task list with grouped data, or shows an empty state message.
    func reload(groups: [(label: String, taskLists: [TaskList])], emptyMessage: String? = nil) {
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
                for taskList in group.taskLists {
                    let row = makeTaskListRow(taskList)
                    contentStack.addArrangedSubview(row)
                }
            }
        }
    }

    /// Resets scroll position to show the very first item.
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

    private func makeTaskListRow(_ taskList: TaskList) -> NSView {
        let row = TaskListRowView(taskList: taskList)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.onSelect = { [weak self] in
            self?.onSelectTaskList?(taskList)
        }
        row.onDelete = { [weak self] in
            self?.onDeleteTaskList?(taskList)
        }
        return row
    }
}

// MARK: - Task List Row View

/// A single task list row with hover highlight, delete button, and click handling.
private final class TaskListRowView: NSView {
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    private let taskList: TaskList
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

    private lazy var deleteButtonHoverTracker: TaskDeleteButtonHoverTracker = .init(button: deleteButton)

    private let timeLabel = NSTextField(labelWithString: "")

    init(taskList: TaskList) {
        self.taskList = taskList
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
        let iconImage = MenuBarIcon.symbolIcon(name: "checklist", size: iconSize)
        let iconView = NSImageView(image: iconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let completed = taskList.items.filter(\.isCompleted).count
        let total = taskList.items.count
        let subtitle = "\(completed)/\(total)"

        let titleLabel = NSTextField(labelWithString: taskList.title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: subtitle)
        countLabel.font = .systemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        timeLabel.stringValue = Self.relativeTime(taskList.updatedAt)
        timeLabel.font = .systemFont(ofSize: 22, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(timeLabel)
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

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),

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
private final class TaskDeleteButtonHoverTracker: NSResponder {
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
private final class TaskFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
