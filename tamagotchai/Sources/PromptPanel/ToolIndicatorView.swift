import AppKit

/// A small glassmorphism pill that shows which tool is currently running.
final class ToolIndicatorView: NSView {
    private let pillRadius: CGFloat = 12

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

            label.widthAnchor.constraint(equalToConstant: 100),

            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func displayName(for toolName: String) -> String {
        switch toolName {
        case "bash": "Running bash…"
        case "read": "Reading file…"
        case "write": "Writing file…"
        case "edit": "Editing file…"
        case "ls": "Listing dir…"
        case "find": "Finding files…"
        case "grep": "Searching…"
        case "web_fetch": "Fetching URL…"
        case "web_search": "Searching web…"
        default: "Working…"
        }
    }

    func show(toolName: String) {
        let displayText = Self.displayName(for: toolName)
        spinner.startAnimation(nil)
        isHidden = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            self.label.stringValue = displayText
            self.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                self?.isHidden = true
                self?.spinner.stopAnimation(nil)
            }
        }
    }
}
