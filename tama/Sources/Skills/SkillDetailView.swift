import AppKit

/// Displays a skill's details with rendered markdown, matching the notification panel style.
final class SkillDetailView: NSView {
    private let skill: Skill

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

    private lazy var textView: NSTextView = {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesAdaptiveColorMappingForDarkAppearance = true
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 20, height: 16)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        return tv
    }()

    init(skill: Skill) {
        self.skill = skill
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Build content: title + description + divider + skill content
        var content = ""

        // Title as heading
        content += "# \(skill.name)\n\n"

        // Description if present
        if !skill.description.isEmpty {
            content += "## \(skill.description)\n\n"
        }

        // Divider
        content += "---\n\n"

        // Skill content
        content += skill.content

        // Render markdown
        let rendered = MarkdownRenderer.render(content)
        textView.textStorage?.setAttributedString(rendered)
    }
}
