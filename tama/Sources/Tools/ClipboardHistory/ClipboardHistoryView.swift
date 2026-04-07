import AppKit

/// Displays clipboard history entries in a scrollable, filterable list.
/// Clicking an entry copies it back to the pasteboard.
final class ClipboardHistoryView: NSView {
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

    private var currentQuery = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
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

    func filter(query: String) {
        currentQuery = query
        reload()
    }

    private func reload() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let entries = ClipboardStore.shared.search(query: currentQuery)

        if entries.isEmpty {
            let message = currentQuery.isEmpty
                ? "Clipboard history is empty."
                : "No matches found."
            contentStack.addArrangedSubview(makeEmptyState(message))
        } else {
            let groups = Self.groupByDate(entries)
            for group in groups {
                contentStack.addArrangedSubview(makeSectionHeader(group.label))
                for entry in group.entries {
                    let row = ClipboardEntryRowView(entry: entry)
                    row.translatesAutoresizingMaskIntoConstraints = false
                    row.heightAnchor.constraint(equalToConstant: 44).isActive = true
                    row.onSelect = { [weak self] in
                        self?.copyEntry(entry)
                    }
                    row.onDelete = { [weak self] in
                        ClipboardStore.shared.delete(entry)
                        self?.reload()
                    }
                    contentStack.addArrangedSubview(row)
                }
            }
        }
    }

    /// Groups entries by date using the same buckets as SessionStore:
    /// "Today", "This Week", "This Month", "Older".
    private static func groupByDate(_ entries: [ClipboardEntry]) -> [(label: String, entries: [ClipboardEntry])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? startOfToday
        let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? startOfToday

        var today: [ClipboardEntry] = []
        var thisWeek: [ClipboardEntry] = []
        var thisMonth: [ClipboardEntry] = []
        var older: [ClipboardEntry] = []

        for entry in entries {
            if entry.timestamp >= startOfToday {
                today.append(entry)
            } else if entry.timestamp >= startOfWeek {
                thisWeek.append(entry)
            } else if entry.timestamp >= startOfMonth {
                thisMonth.append(entry)
            } else {
                older.append(entry)
            }
        }

        var result: [(label: String, entries: [ClipboardEntry])] = []
        if !today.isEmpty { result.append(("Today", today)) }
        if !thisWeek.isEmpty { result.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { result.append(("This Month", thisMonth)) }
        if !older.isEmpty { result.append(("Older", older)) }
        return result
    }

    /// Section header matching SessionListView.makeSectionHeader exactly.
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

    private func copyEntry(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        ClipboardMonitor.shared.skipNextChange = true
        pb.clearContents()

        switch entry.contentType {
        case .text:
            if let text = entry.textContent {
                pb.setString(text, forType: .string)
            }
        case .fileURL:
            if let path = entry.fileURL,
               let url = URL(string: "file://" + path)
            {
                pb.writeObjects([url as NSURL])
            }
        case .image:
            if let data = entry.imageData {
                pb.setData(data, forType: .png)
            }
        }
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

// MARK: - Entry Row View

/// A single clipboard entry row with preview text, timestamp, and delete button on hover.
private final class ClipboardEntryRowView: NSView {
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let timeLabel = NSTextField(labelWithString: "")

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

    private lazy var deleteButtonHoverTracker: DeleteButtonHoverTracker = .init(button: deleteButton)

    private lazy var copiedOverlay: NSView = {
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
        overlay.layer?.cornerRadius = 6
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.alphaValue = 0
        overlay.isHidden = true

        let label = NSTextField(labelWithString: "Copied")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        return overlay
    }()

    init(entry: ClipboardEntry) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlightLayer)
        setupViews(entry: entry)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews(entry: ClipboardEntry) {
        let iconName = switch entry.contentType {
        case .text: "doc.text"
        case .image: "photo"
        case .fileURL: "doc"
        }

        let iconSize: CGFloat = 28
        let iconImage = MenuBarIcon.symbolIcon(name: iconName, size: iconSize)
        let iconView = NSImageView(image: iconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let previewLabel = NSTextField(labelWithString: entry.preview)
        previewLabel.font = .systemFont(ofSize: 18, weight: .regular)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.cell?.wraps = false
        previewLabel.cell?.isScrollable = false
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        // Trailing metadata: source app name + relative time
        let timeParts: [String] = [entry.sourceAppName, Self.relativeTime(entry.timestamp)]
            .compactMap(\.self)
        timeLabel.stringValue = timeParts.joined(separator: " · ")
        timeLabel.font = .systemFont(ofSize: 22, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(previewLabel)
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

            previewLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -12),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Set up hover tracking on delete button
        _ = deleteButtonHoverTracker

        // "Copied" overlay — covers the row, hidden by default
        addSubview(copiedOverlay)
        NSLayoutConstraint.activate([
            copiedOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            copiedOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            copiedOverlay.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            copiedOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
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
        // Don't trigger select if clicking the delete button
        let loc = convert(event.locationInWindow, from: nil)
        if deleteButton.frame.contains(loc) { return }
        ButtonSound.shared.play()
        super.mouseDown(with: event)
        onSelect?()
        showCopiedFeedback()
    }

    private func showCopiedFeedback() {
        copiedOverlay.isHidden = false
        copiedOverlay.alphaValue = 0

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            copiedOverlay.animator().alphaValue = 1
        } completionHandler: {
            // Hold briefly, then fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.copiedOverlay.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { [weak self] in
                        self?.copiedOverlay.isHidden = true
                    }
                }
            }
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
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

/// An NSView with a flipped coordinate system (origin at top-left).
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
