import AppKit

/// A borderless, floating NSPanel that mimics macOS Spotlight's window behavior.
/// - Appears centered on the active screen
/// - Floats above all windows
/// - Dismisses when focus is lost or Escape is pressed
/// - Grows downward from a fixed top edge when content expands
final class FloatingPanel: NSPanel, NSTextFieldDelegate {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The panel width.
    private let panelWidth: CGFloat = 680

    /// The input bar height.
    private let inputHeight: CGFloat = 58

    /// Max height for the response area.
    private let responseMaxHeight: CGFloat = 400

    /// The stored top edge so the panel grows downward, not upward.
    private var topY: CGFloat = 0

    /// Tracks whether we're currently dismissing to avoid re-entrant calls.
    private var isDismissing = false

    /// Height constraint for the response scroll view.
    private var responseHeightConstraint: NSLayoutConstraint?

    /// Called when the user presses Return in the text field.
    var onSubmit: ((String) -> Void)?

    /// Called when the user types in the input field.
    var onTextChanged: ((String) -> Void)?

    // MARK: - UI Components

    /// The animated mascot inline in the input row.
    let mascot = MascotView()

    private lazy var inputField: NSTextField = {
        let field = WhiteCursorTextField()
        field.delegate = self
        field.placeholderString = "Ask anything…"
        field.font = .systemFont(ofSize: 26, weight: .light)
        field.textColor = .labelColor
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    /// Invisible spacer that reserves space for the mascot child window.
    private lazy var mascotSpacer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 40),
            v.heightAnchor.constraint(equalToConstant: 40),
        ])
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }()

    private lazy var inputRow: NSStackView = {
        let stack = NSStackView(views: [mascotSpacer, inputField])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: inputHeight).isActive = true
        return stack
    }()

    private lazy var dividerContainer: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }()

    /// The response text view — read-only, selectable, scrollable.
    private lazy var responseTextView: NSTextView = {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.autoresizingMask = [.width]
        return textView
    }()

    /// The scroll view wrapping the response text.
    private lazy var responseScrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.documentView = responseTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollerStyle = .overlay
        return scrollView
    }()

    private lazy var mainStack: NSStackView = {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(inputRow)
        return stack
    }()

    /// Corner radius matching Spotlight's pill shape.
    private let cornerRadius: CGFloat = 28

    private lazy var backgroundView: NSVisualEffectView = {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
    }()

    // MARK: - Init

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isMovableByWindowBackground = false
        isMovable = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        setupContentView()
    }

    private func setupContentView() {
        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView = container

        container.addSubview(backgroundView)
        backgroundView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: container.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            mainStack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
        ])

        // Add divider + response to stack once, keep them hidden
        mainStack.addArrangedSubview(dividerContainer)
        mainStack.addArrangedSubview(responseScrollView)

        dividerContainer.isHidden = true
        responseScrollView.isHidden = true

        let heightConstraint = responseScrollView.heightAnchor.constraint(
            equalToConstant: 0
        )
        heightConstraint.isActive = true
        responseHeightConstraint = heightConstraint
    }

    // MARK: - Dismiss on Escape

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            dismiss()
            return
        }
        super.sendEvent(event)
    }

    // MARK: - Dismiss on focus loss

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    // MARK: - NSTextFieldDelegate — Return key

    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = inputField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return true }
            onSubmit?(text)
            return true
        }
        return false
    }

    // MARK: - Response

    /// Shows the response area below the input with the given text.
    func showResponse(_ text: String) {
        responseTextView.string = text

        // Calculate the natural text height
        responseTextView.layoutManager?.ensureLayout(
            for: responseTextView.textContainer!
        )
        let textHeight = responseTextView.layoutManager?.usedRect(
            for: responseTextView.textContainer!
        ).height ?? 100

        // Add text container inset
        let totalTextHeight = textHeight
            + responseTextView.textContainerInset.height * 2

        // Clamp to max height
        let targetHeight = min(totalTextHeight, responseMaxHeight)

        // Set target height and unhide — but start with zero height for animation
        responseHeightConstraint?.constant = 0
        dividerContainer.isHidden = false
        responseScrollView.isHidden = false
        dividerContainer.alphaValue = 1
        responseScrollView.alphaValue = 1

        // Set the initial frame to include divider space only
        let initialPanelHeight = inputHeight + 1
        let initialFrame = NSRect(
            x: frame.origin.x,
            y: topY - initialPanelHeight,
            width: panelWidth,
            height: initialPanelHeight
        )
        setFrame(initialFrame, display: true)

        // Now animate the response area growing downward
        let newPanelHeight = inputHeight + 1 + targetHeight
        let newOriginY = topY - newPanelHeight
        let newFrame = NSRect(
            x: frame.origin.x,
            y: newOriginY,
            width: panelWidth,
            height: newPanelHeight
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.responseHeightConstraint?.animator().constant = targetHeight
            self.animator().setFrame(newFrame, display: true)
        } completionHandler: { [weak self] in
            self?.positionMascotOverSpacer()
        }

        responseTextView.scrollToBeginningOfDocument(nil)
        positionMascotOverSpacer()
        invalidateShadow()
    }

    // MARK: - Text change tracking

    func controlTextDidChange(_: Notification) {
        let text = inputField.stringValue
        onTextChanged?(text)
    }

    // MARK: - Presentation

    func present() {
        isDismissing = false

        // Reset state
        inputField.stringValue = ""
        responseTextView.string = ""
        dividerContainer.isHidden = true
        responseScrollView.isHidden = true
        responseHeightConstraint?.constant = 0
        mascot.setState(.idle)

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame

        let originX = screenFrame.midX - panelWidth / 2
        topY = screenFrame.midY + screenFrame.height * 0.15

        let panelFrame = NSRect(
            x: originX,
            y: topY - inputHeight,
            width: panelWidth,
            height: inputHeight
        )
        setFrame(panelFrame, display: true)

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(inputField)

        // Position mascot child window over the spacer
        mascot.window.alphaValue = 0
        addChildWindow(mascot.window, ordered: .above)
        positionMascotOverSpacer()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.mascot.window.animator().alphaValue = 1
        }
    }

    /// Positions the mascot child window directly over the spacer view.
    private func positionMascotOverSpacer() {
        let spacerInWindow = mascotSpacer.convert(mascotSpacer.bounds, to: nil)
        let spacerOnScreen = convertToScreen(spacerInWindow)
        mascot.window.setFrameOrigin(spacerOnScreen.origin)
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.mascot.window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.removeChildWindow(self.mascot.window)
                self.mascot.window.orderOut(nil)
                self.orderOut(nil)
                self.isDismissing = false
            }
        }
    }
}

// MARK: - Flipped stack view

/// NSStackView subclass with flipped coordinates so arranged subviews
/// stack top-to-bottom (first = top) instead of the default bottom-to-top.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - White cursor text field

/// NSTextField subclass that sets the insertion point (cursor) color to white.
private final class WhiteCursorTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let fieldEditor = currentEditor() as? NSTextView {
            fieldEditor.insertionPointColor = .white
        }
        return result
    }
}
