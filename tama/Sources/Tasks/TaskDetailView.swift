import AppKit

/// Displays the items of a single task list as a scrollable checklist.
final class TaskDetailView: NSView {
    /// Called when a checkbox is toggled: (taskListId, itemId, newIsCompleted).
    var onToggleItem: ((UUID, UUID, Bool) -> Void)?

    private var taskList: TaskList

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
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return stack
    }()

    init(taskList: TaskList) {
        self.taskList = taskList
        super.init(frame: .zero)
        setup()
        reload()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let docView = TaskDetailFlippedDocumentView()
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

    /// Updates the displayed task list and rebuilds the UI.
    func update(taskList: TaskList) {
        self.taskList = taskList
        reload()
    }

    private func reload() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Title header
        let titleLabel = NSTextField(labelWithString: taskList.title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleContainer = NSView()
        titleContainer.translatesAutoresizingMaskIntoConstraints = false
        titleContainer.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleContainer.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: titleContainer.leadingAnchor, constant: 20),
            titleLabel.centerYAnchor.constraint(equalTo: titleContainer.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleContainer.trailingAnchor, constant: -20),
        ])
        contentStack.addArrangedSubview(titleContainer)

        // Task items
        for item in taskList.items {
            let row = makeItemRow(item)
            contentStack.addArrangedSubview(row)
        }

        // Empty state
        if taskList.items.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No items in this task list.")
            emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false

            let emptyContainer = NSView()
            emptyContainer.translatesAutoresizingMaskIntoConstraints = false
            emptyContainer.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyContainer.heightAnchor.constraint(equalToConstant: 60),
                emptyLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor),
            ])
            contentStack.addArrangedSubview(emptyContainer)
        }
    }

    private func makeItemRow(_ item: TaskItem) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        checkbox.state = item.isCompleted ? .on : .off
        checkbox.tag = item.id.hashValue
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        // Store item ID for lookup
        checkbox.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)

        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = item.isCompleted ? .tertiaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        // Strikethrough for completed items
        if item.isCompleted {
            let attributed = NSMutableAttributedString(string: item.title)
            attributed.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: attributed.length)
            )
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                range: NSRange(location: 0, length: attributed.length)
            )
            attributed.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: 14, weight: .regular),
                range: NSRange(location: 0, length: attributed.length)
            )
            label.attributedStringValue = attributed
        }

        container.addSubview(checkbox)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 36),

            checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])

        return container
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let itemIdString = sender.identifier?.rawValue,
              let itemId = UUID(uuidString: itemIdString)
        else { return }

        let newState = sender.state == .on
        onToggleItem?(taskList.id, itemId, newState)
    }
}

// MARK: - Flipped Document View

private final class TaskDetailFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
