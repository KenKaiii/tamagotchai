import AppKit

/// A custom tab bar with a sliding highlight indicator that animates between tabs.
final class AnimatedTabBar: NSView {
    private let labels: [String]
    private let onSelect: (Int) -> Void
    private var buttons: [NSButton] = []
    private var selectedIndex = 0

    private let highlightView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.38, alpha: 1).cgColor
        v.layer?.cornerRadius = 6
        return v
    }()

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    init(labels: [String], onSelect: @escaping (Int) -> Void) {
        self.labels = labels
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        addSubview(highlightView)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        for (index, label) in labels.enumerated() {
            if index > 0 {
                stackView.addArrangedSubview(makeDivider())
            }
            let button = makeTabButton(title: label, tag: index)
            buttons.append(button)
            stackView.addArrangedSubview(button)
        }

        updateButtonAppearance()
    }

    private func makeTabButton(title: String, tag: Int) -> NSButton {
        let button = PaddedTabButton()
        button.title = title
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.isBordered = false
        button.tag = tag
        button.target = self
        button.action = #selector(tabClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = .white
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 14),
        ])
        return divider
    }

    @objc private func tabClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index != selectedIndex else { return }
        selectTab(index, animated: true)
        onSelect(index)
    }

    /// Selects a tab programmatically.
    func selectTab(_ index: Int, animated: Bool) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        updateButtonAppearance()

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.positionHighlight()
            }
        } else {
            positionHighlight()
        }
    }

    private func updateButtonAppearance() {
        for (index, button) in buttons.enumerated() {
            button.contentTintColor = index == selectedIndex
                ? .white
                : .white.withAlphaComponent(0.5)
        }

        // Hide dividers adjacent to the selected tab so they don't
        // poke through the highlight pill
        let dividers = stackView.arrangedSubviews.filter { !($0 is NSButton) }
        for divider in dividers {
            divider.alphaValue = 1
        }
        // Divider before selected tab (at stack index selectedIndex * 2 - 1)
        let beforeIndex = selectedIndex * 2 - 1
        if beforeIndex >= 0, beforeIndex < stackView.arrangedSubviews.count {
            stackView.arrangedSubviews[beforeIndex].alphaValue = 0
        }
        // Divider after selected tab (at stack index selectedIndex * 2 + 1)
        let afterIndex = selectedIndex * 2 + 1
        if afterIndex < stackView.arrangedSubviews.count {
            stackView.arrangedSubviews[afterIndex].alphaValue = 0
        }
    }

    private func positionHighlight() {
        guard selectedIndex < buttons.count else { return }
        let button = buttons[selectedIndex]
        let buttonFrame = button.convert(button.bounds, to: self)
        highlightView.frame = buttonFrame.insetBy(dx: -1, dy: 0)
    }

    override func layout() {
        super.layout()
        positionHighlight()
    }
}

/// An NSButton subclass that adds horizontal padding around its title.
private final class PaddedTabButton: NSButton {
    private let horizontalPadding: CGFloat = 12

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding * 2
        return size
    }
}
