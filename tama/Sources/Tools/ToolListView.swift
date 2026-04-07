import AppKit

/// Displays a filterable list of panel tools in the Tools tab.
final class ToolListView: NSView {
    /// Called when the user clicks a tool row.
    var onSelectTool: ((PanelTool) -> Void)?

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

    /// Reloads the tool list with the given tools.
    func reload(tools: [PanelTool]) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if tools.isEmpty {
            contentStack.addArrangedSubview(makeEmptyState("No tools found."))
        } else {
            for tool in tools {
                let row = ToolRowView(tool: tool)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 52).isActive = true
                // Toggle tools handle interaction inline — no drilldown
                if tool is any TogglePanelTool {
                    // No onSelect needed; ToolRowView handles toggle clicks directly
                } else {
                    row.onSelect = { [weak self] in
                        self?.onSelectTool?(tool)
                    }
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

/// An NSView with a flipped coordinate system (origin at top-left)
/// so that scroll views display content from the top down.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
