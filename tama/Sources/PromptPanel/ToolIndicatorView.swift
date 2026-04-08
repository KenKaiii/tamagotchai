import AppKit

/// A small glassmorphism pill that shows which tool is currently running.
final class ToolIndicatorView: NSView {
    private let pillRadius: CGFloat = 12
    private var isGenerating = false

    /// Minimum width for the pill (fits "Generating" comfortably)
    private let minWidth: CGFloat = 130

    /// Maximum width for the pill to prevent overflow (leaves margin on right side)
    private let maxWidth: CGFloat = 280

    /// Width constraint that gets updated dynamically
    private var widthConstraint: NSLayoutConstraint?

    private let vibrancy: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .withinWindow
        v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.style = .spinning
        p.controlSize = .small
        p.isIndeterminate = true
        p.translatesAutoresizingMaskIntoConstraints = false
        return p
    }()

    private let label: NSTextField = {
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = NSColor.white.withAlphaComponent(0.85)
        t.lineBreakMode = .byTruncatingTail
        t.maximumNumberOfLines = 1
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = pillRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        addSubview(vibrancy)
        NSLayoutConstraint.activate([
            vibrancy.leadingAnchor.constraint(equalTo: leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: trailingAnchor),
            vibrancy.topAnchor.constraint(equalTo: topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        vibrancy.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: vibrancy.trailingAnchor),
            stack.topAnchor.constraint(equalTo: vibrancy.topAnchor),
            stack.bottomAnchor.constraint(equalTo: vibrancy.bottomAnchor),

            // Ensure label doesn't overflow - it will truncate with ellipsis
            label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth - 44),

            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Set up dynamic width constraint
        let widthConstraint = widthAnchor.constraint(equalToConstant: minWidth)
        widthConstraint.priority = .required
        widthConstraint.isActive = true
        self.widthConstraint = widthConstraint

        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Display Name

    static func displayName(for toolName: String, args: [String: String] = [:]) -> String {
        switch toolName {
        case "bash":
            let cmd = compact(args["command"], max: 36)
            return cmd.isEmpty ? "Running command…" : "Running  \(cmd)"
        case "read":
            if let file = lastComponent(args["file_path"]) { return "Reading  \(file)" }
            return "Reading file…"
        case "write":
            if let file = lastComponent(args["file_path"]) { return "Writing  \(file)" }
            return "Writing file…"
        case "edit":
            if let file = lastComponent(args["file_path"]) { return "Editing  \(file)" }
            return "Editing file…"
        case "ls":
            let dir = lastComponent(args["path"]) ?? "."
            return "Listing  \(dir)"
        case "find":
            let pattern = compact(args["pattern"], max: 28)
            return pattern.isEmpty ? "Finding files…" : "Finding  \(pattern)"
        case "grep":
            let pattern = compact(args["pattern"], max: 28)
            return pattern.isEmpty ? "Searching files…" : "Searching  \(pattern)"
        case "web_fetch":
            if let url = args["url"], let host = URL(string: url)?.host {
                return "Fetching  \(host)"
            }
            return "Fetching page…"
        case "web_search":
            let query = compact(args["query"], max: 28)
            return query.isEmpty ? "Searching the web…" : "Searching  \(query)"
        case "browser":
            return browserDisplayName(args: args)
        case "create_reminder":
            let name = compact(args["name"], max: 28)
            return name.isEmpty ? "Setting reminder…" : "Reminder  \(name)"
        case "create_routine":
            let name = compact(args["name"], max: 28)
            return name.isEmpty ? "Setting routine…" : "Routine  \(name)"
        case "list_schedules":
            return "Checking schedules…"
        case "delete_schedule":
            let name = compact(args["name"], max: 28)
            return name.isEmpty ? "Removing schedule…" : "Removing  \(name)"
        case "task":
            return "Managing tasks…"
        default:
            return "Working…"
        }
    }

    // MARK: - Browser Actions

    private static func browserDisplayName(args: [String: String]) -> String {
        let action = args["action"] ?? ""
        switch action {
        case "navigate":
            if let url = args["url"], let host = URL(string: url)?.host {
                return "Opening  \(host)"
            }
            return "Navigating…"
        case "click":
            let sel = compact(args["selector"], max: 24)
            return sel.isEmpty ? "Clicking element…" : "Clicking  \(sel)"
        case "type":
            let text = compact(args["text"], max: 24)
            return text.isEmpty ? "Typing…" : "Typing  \(text)"
        case "get_text":
            let sel = compact(args["selector"], max: 24)
            return sel.isEmpty ? "Reading page…" : "Reading  \(sel)"
        case "get_html":
            return "Reading page source…"
        case "screenshot":
            return "Taking screenshot…"
        case "evaluate":
            return "Evaluating script…"
        case "wait":
            let sel = compact(args["selector"], max: 24)
            return sel.isEmpty ? "Waiting for element…" : "Waiting for  \(sel)"
        default:
            return "Browsing…"
        }
    }

    // MARK: - Helpers

    /// Truncates a value for pill display, returning empty string for nil/empty.
    private static func compact(_ value: String?, max: Int) -> String {
        guard let value, !value.isEmpty else { return "" }
        // Collapse whitespace for commands
        let cleaned = value.components(separatedBy: .newlines).first ?? value
        if cleaned.count <= max { return cleaned }
        return String(cleaned.prefix(max - 1)) + "…"
    }

    /// Returns the last path component, or nil if empty.
    private static func lastComponent(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    func show(toolName: String, args: [String: String] = [:]) {
        isGenerating = false // No longer generating when tool starts
        let displayText = Self.displayName(for: toolName, args: args)
        spinner.startAnimation(nil)
        isHidden = false

        // Update width based on text content before showing
        updateWidth(for: displayText)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            self.label.stringValue = displayText
            self.animator().alphaValue = 1
        }
    }

    /// Calculates and updates the pill width based on the text content.
    private func updateWidth(for text: String) {
        // Calculate the width needed for the text
        let font = label.font ?? .systemFont(ofSize: 11, weight: .medium)
        let textSize = (text as NSString).size(withAttributes: [.font: font])

        // Add padding for the stack view insets and spacing
        // Stack insets: left 10, right 12 | Spinner: 16 | Spacing: 6 | Safety buffer: 8
        let padding: CGFloat = 10 + 12 + 16 + 6 + 8
        let targetWidth = textSize.width + padding

        // Clamp to min/max bounds
        let clampedWidth = max(minWidth, min(maxWidth, targetWidth))

        widthConstraint?.constant = clampedWidth
        layoutSubtreeIfNeeded()
    }

    @discardableResult
    func hide() -> Bool {
        // Don't hide if in generating mode
        if isGenerating { return false }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                // Don't hide if we started generating while animating
                guard let self, !self.isGenerating else { return }
                isHidden = true
                spinner.stopAnimation(nil)
            }
        }
        return true
    }

    /// Shows the "Generating" indicator.
    func showGenerating() {
        isGenerating = true
        let displayText = "Generating"
        label.stringValue = displayText
        spinner.startAnimation(nil)
        isHidden = false

        // Update width for "Generating" text
        updateWidth(for: displayText)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 1
        }
    }

    /// Hides the generating indicator.
    func hideThinking() {
        isGenerating = false
        spinner.stopAnimation(nil)
        alphaValue = 0
        isHidden = true
    }
}
