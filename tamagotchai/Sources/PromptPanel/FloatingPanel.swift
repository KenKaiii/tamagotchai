import AppKit
import CoreVideo

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

    /// Raw markdown text accumulated during streaming.
    private var rawMarkdown = ""

    // MARK: - Character queue streaming

    /// Characters waiting to be "typed" onto screen.
    private var characterQueue: [Character] = []

    /// The markdown text displayed so far (typed out character by character).
    private var displayedMarkdown = ""

    /// Full raw text received from API so far.
    private var pendingMarkdown = ""

    /// Accumulated attributed string from all previous conversation turns.
    private var conversationAttributed = NSMutableAttributedString()

    /// Length of conversation history in the text storage (streaming appends after this).
    private var conversationBaseLength = 0

    /// Blinking cursor glyph shown at the end of streaming text.
    private static let streamingCursorGlyph = "▍"

    /// Whether the streaming cursor is currently visible (toggles for blink effect).
    private var cursorVisible = true

    /// Timer that toggles the cursor blink state.
    private var cursorBlinkTimer: Timer?

    /// CVDisplayLink that drives the typing animation in sync with the screen refresh rate.
    private var displayLink: CVDisplayLink?

    /// Timestamp of the last display link frame (for calculating elapsed time).
    private var lastFrameTime: CFTimeInterval = 0

    /// Timestamp of the last full markdown re-render.
    private var lastFullRenderTime: CFTimeInterval = 0

    /// Whether the stream has finished delivering all deltas.
    private var streamFinished = false

    /// Length of displayedMarkdown at last markdown re-render.
    private var lastRenderLength = 0

    /// Last computed target height to skip no-op updates.
    private var lastTargetHeight: CGFloat = 0

    /// Whether auto-scroll is active. Disabled when user scrolls up, re-enabled on new message.
    private var autoScrollEnabled = true

    /// Once the panel reaches max height, it stays there for the session.
    private var reachedMaxHeight = false

    /// Skeleton shimmer view shown while waiting for first token.
    private lazy var skeletonView: SkeletonView = {
        let v = SkeletonView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

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

    /// The response text view — read-only, selectable, scrollable, rich-text for markdown.
    private lazy var responseTextView: NSTextView = {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true
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
        textView.isAutomaticLinkDetectionEnabled = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return textView
    }()

    /// The scroll view wrapping the response text.
    private lazy var responseScrollView: ConditionalScrollView = {
        let scrollView = ConditionalScrollView()
        scrollView.documentView = responseTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
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

        responseScrollView.onUserScroll = { [weak self] in
            self?.autoScrollEnabled = false
        }

        // Add skeleton shimmer overlay inside responseScrollView
        responseScrollView.addSubview(skeletonView)
        NSLayoutConstraint.activate([
            skeletonView.leadingAnchor.constraint(equalTo: responseScrollView.leadingAnchor, constant: 24),
            skeletonView.trailingAnchor.constraint(equalTo: responseScrollView.trailingAnchor, constant: -24),
            skeletonView.topAnchor.constraint(equalTo: responseScrollView.topAnchor, constant: 14),
            skeletonView.heightAnchor.constraint(equalToConstant: 60),
        ])
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

    /// Shows the response area below the input with the given text (rendered as markdown).
    func showResponse(_ text: String) {
        rawMarkdown = text
        let attributed = MarkdownRenderer.render(text)
        responseTextView.textStorage?.setAttributedString(attributed)

        // Calculate the natural text height
        let textHeight = measureTextHeight()
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
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                self?.positionMascotOverSpacer()
            }
        }

        responseTextView.scrollToBeginningOfDocument(nil)
        positionMascotOverSpacer()
        invalidateShadow()
        inputField.stringValue = ""
        makeFirstResponder(inputField)
    }

    /// Streams text deltas into the response area with smooth character-by-character typing.
    /// Returns the full assistant response text for conversation history tracking.
    @discardableResult
    func streamResponse(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        // Build user bubble attributed string before appending
        let userText = inputField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userBubble = userText.isEmpty ? nil : makeUserBubble(userText)

        // Re-enable auto-scroll for new message
        autoScrollEnabled = true

        // Append to conversation source of truth
        if let userBubble {
            conversationAttributed.append(userBubble)
        }

        // Reset streaming state
        rawMarkdown = ""
        pendingMarkdown = ""
        displayedMarkdown = ""
        characterQueue = []
        streamFinished = false
        lastRenderLength = 0
        if !reachedMaxHeight { lastTargetHeight = 0 }
        lastFrameTime = 0
        lastFullRenderTime = 0
        stopDisplayLink()
        stopCursorBlink()

        let isFirstMessage = conversationBaseLength == 0

        // Suppress all animations during content update + scroll
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isFirstMessage {
            // First message: set full text storage
            if let storage = responseTextView.textStorage {
                storage.beginEditing()
                storage.setAttributedString(conversationAttributed)
                storage.endEditing()
            }
        } else if let userBubble, let storage = responseTextView.textStorage {
            // Subsequent: append only the new user bubble at the tail
            let insertPos = conversationBaseLength
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: insertPos, length: storage.length - insertPos),
                with: userBubble
            )
            storage.endEditing()
        }
        conversationBaseLength = conversationAttributed.length

        dividerContainer.isHidden = false
        responseScrollView.isHidden = false
        dividerContainer.alphaValue = 1
        responseScrollView.alphaValue = 1

        // Force layout so the right-aligned bubble renders correctly
        if let tc = responseTextView.textContainer {
            responseTextView.layoutManager?.ensureLayout(for: tc)
        }
        responseScrollView.layoutSubtreeIfNeeded()

        // On subsequent messages, lock to max height immediately to prevent
        // gradual panel growth that causes content to slide.
        if !isFirstMessage, !reachedMaxHeight {
            reachedMaxHeight = true
            responseHeightConstraint?.constant = responseMaxHeight
            responseScrollView.hasVerticalScroller = true
            lastTargetHeight = responseMaxHeight
            let panelHeight = inputHeight + 1 + responseMaxHeight
            let newOriginY = topY - panelHeight
            setFrame(
                NSRect(
                    x: frame.origin.x, y: newOriginY,
                    width: panelWidth, height: panelHeight
                ),
                display: false
            )
            positionMascotOverSpacer()
        }

        scrollToBottomInstantly()

        CATransaction.commit()
        NSAnimationContext.endGrouping()

        // Clear input immediately
        inputField.stringValue = ""

        // Show skeleton and animate panel expand (skip when already at max)
        if !reachedMaxHeight {
            let skeletonHeight: CGFloat = 80
            skeletonView.isHidden = false
            skeletonView.startAnimating()

            let currentTextHeight = computeTextHeight()
            let targetSkeletonHeight = min(
                max(currentTextHeight, skeletonHeight),
                responseMaxHeight
            )
            let newPanelHeight = inputHeight + 1 + targetSkeletonHeight
            let newOriginY = topY - newPanelHeight
            let newFrame = NSRect(
                x: frame.origin.x,
                y: newOriginY,
                width: panelWidth,
                height: newPanelHeight
            )

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.responseHeightConstraint?.animator().constant = targetSkeletonHeight
                self.animator().setFrame(newFrame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { [weak self] in
                    self?.positionMascotOverSpacer()
                }
            }
            invalidateShadow()
        }

        var receivedFirst = false
        for try await delta in stream {
            pendingMarkdown += delta
            characterQueue.append(contentsOf: delta)

            if !receivedFirst {
                receivedFirst = true
                // Hide skeleton if it was shown
                if !skeletonView.isHidden {
                    skeletonView.stopAnimating()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        self.skeletonView.animator().alphaValue = 0
                    } completionHandler: {
                        MainActor.assumeIsolated { [weak self] in
                            self?.skeletonView.isHidden = true
                            self?.skeletonView.alphaValue = 1
                        }
                    }
                }
                mascot.setState(.responding)
                startDisplayLink()
            }
        }

        // Stream ended — mark finished so typing timer knows to drain and stop
        rawMarkdown = pendingMarkdown
        streamFinished = true

        // If we never received any text, clean up skeleton
        if !receivedFirst {
            skeletonView.stopAnimating()
            skeletonView.isHidden = true
        }

        return pendingMarkdown
    }

    /// Creates a right-aligned chat bubble attributed string for the user's message.
    private func makeUserBubble(_ text: String) -> NSAttributedString {
        let bubbleFont = NSFont.systemFont(ofSize: 18, weight: .regular)
        let hPad: CGFloat = 14
        let vPad: CGFloat = 8
        let radius: CGFloat = 16
        let bubbleColor = NSColor.systemBlue
        let maxTextWidth = panelWidth * 0.6

        // Measure text size
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bubbleFont,
            .foregroundColor: NSColor.white,
        ]
        let textRect = (text as NSString).boundingRect(
            with: NSSize(
                width: maxTextWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let bubbleW = ceil(textRect.width) + hPad * 2
        let bubbleH = ceil(textRect.height) + vPad * 2

        // Draw bubble into an image
        let image = NSImage(
            size: NSSize(width: bubbleW, height: bubbleH)
        )
        image.lockFocus()
        let path = NSBezierPath(
            roundedRect: NSRect(
                x: 0, y: 0, width: bubbleW, height: bubbleH
            ),
            xRadius: radius, yRadius: radius
        )
        bubbleColor.setFill()
        path.fill()
        let drawRect = NSRect(
            x: hPad, y: vPad,
            width: textRect.width, height: textRect.height
        )
        (text as NSString).draw(in: drawRect, withAttributes: attrs)
        image.unlockFocus()

        // Create attachment
        let attachment = NSTextAttachment()
        let cell = NSTextAttachmentCell(imageCell: image)
        attachment.attachmentCell = cell

        let result = NSMutableAttributedString()

        // Right-aligned paragraph
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.paragraphSpacingBefore =
            conversationAttributed.length > 0 ? 8 : 0
        style.paragraphSpacing = 8

        let attachStr = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: attachment)
        )
        attachStr.addAttribute(
            .paragraphStyle, value: style,
            range: NSRange(location: 0, length: attachStr.length)
        )
        result.append(attachStr)
        result.append(NSAttributedString(
            string: "\n",
            attributes: [.font: bubbleFont, .paragraphStyle: style]
        ))
        return result
    }

    /// Computes the current text content height including insets.
    private func computeTextHeight() -> CGFloat {
        let raw = measureTextHeight()
        return raw + responseTextView.textContainerInset.height * 2
    }

    /// Measures the raw text layout height, trying TextKit 2 first then TextKit 1.
    private func measureTextHeight() -> CGFloat {
        // Try TextKit 2
        if let tlm = responseTextView.textLayoutManager,
           let tcm = tlm.textContentManager
        {
            tlm.ensureLayout(for: tcm.documentRange)
            let used = tlm.usageBoundsForTextContainer.height
            if used > 0 { return used }
        }
        // Fallback to TextKit 1 (needed when NSTextBlock is present)
        if let lm = responseTextView.layoutManager,
           let tc = responseTextView.textContainer
        {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            if used > 0 { return used }
        }
        return 40
    }

    /// Starts a CVDisplayLink that drives the typing animation in sync with the display refresh rate.
    private func startDisplayLink() {
        stopDisplayLink()
        lastFrameTime = CACurrentMediaTime()
        lastFullRenderTime = lastFrameTime
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async { self?.displayLinkFired() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        startCursorBlink()
    }

    /// Stops and releases the CVDisplayLink.
    private func stopDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
    }

    /// Starts the cursor blink timer (~2 blinks per second).
    private func startCursorBlink() {
        cursorVisible = true
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            cursorVisible.toggle()
            renderDisplayedMarkdown()
        }
        RunLoop.main.add(cursorBlinkTimer!, forMode: .common)
    }

    /// Stops the cursor blink and hides the cursor.
    private func stopCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorVisible = false
    }

    /// Called every display refresh frame. Pops a proportional number of characters
    /// and batches text storage updates to reduce re-render overhead.
    private func displayLinkFired() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTime
        lastFrameTime = now

        guard !characterQueue.isEmpty else {
            if streamFinished {
                finishTyping()
            }
            return
        }

        // Target ~800 chars/sec; pop proportional to elapsed time
        let charsPerSecond: Double = 800
        let count = max(1, min(characterQueue.count, Int(charsPerSecond * elapsed)))
        let chars = characterQueue.prefix(count)
        characterQueue.removeFirst(count)
        let typedCount = pendingMarkdown.count - characterQueue.count
        displayedMarkdown = String(pendingMarkdown.prefix(typedCount))

        // Full markdown render every frame — display link caps us at ~60Hz so this is fine
        renderDisplayedMarkdown()

        // Always update height so the panel keeps up with growing text
        updateHeight(animated: false)

        // If queue drained and stream done, finish
        if characterQueue.isEmpty, streamFinished {
            finishTyping()
        }
    }

    /// Final render when all characters have been typed.
    private func finishTyping() {
        stopDisplayLink()
        stopCursorBlink()
        // Commit assistant response into conversation attributed
        let rendered = MarkdownRenderer.render(pendingMarkdown)
        conversationAttributed.append(rendered)
        // Update base length BEFORE render so the tail replace doesn't wipe it
        conversationBaseLength = conversationAttributed.length
        displayedMarkdown = ""
        renderDisplayedMarkdown()
        updateHeight(animated: true)
        mascot.setState(.idle)
        // Clear input and refocus for follow-up
        inputField.stringValue = ""
        makeFirstResponder(inputField)
    }

    /// Re-renders the current displayedMarkdown into the text view,
    /// preserving scroll position if the user has scrolled up.
    /// During streaming, appends a blinking cursor glyph at the end of the text.
    private func renderDisplayedMarkdown() {
        guard let storage = responseTextView.textStorage else { return }

        // Append cursor glyph during streaming if visible
        let textToRender = if !streamFinished, cursorVisible {
            displayedMarkdown + Self.streamingCursorGlyph
        } else {
            displayedMarkdown
        }

        let rendered = MarkdownRenderer.render(textToRender)

        // Replace only the streaming tail — leave conversation history untouched
        let tailRange = NSRange(
            location: conversationBaseLength,
            length: storage.length - conversationBaseLength
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        storage.beginEditing()
        storage.replaceCharacters(in: tailRange, with: rendered)
        storage.endEditing()
        CATransaction.commit()

        // Auto-scroll to keep latest content visible
        if autoScrollEnabled {
            scrollToBottomInstantly()
        }
    }

    /// Updates the response area height based on current text content.
    /// When `animated` is false, the frame is set instantly (used during streaming to avoid jitter).
    /// When `animated` is true, a smooth transition is used (for the final settle after typing ends).
    private func updateHeight(animated: Bool) {
        // Once we've hit max height, stay there permanently
        if reachedMaxHeight {
            responseScrollView.hasVerticalScroller = true
            responseHeightConstraint?.constant = responseMaxHeight
            lastTargetHeight = responseMaxHeight
            if autoScrollEnabled { scrollToBottomInstantly() }
            return
        }

        let textHeight = measureTextHeight()

        let totalTextHeight = textHeight
            + responseTextView.textContainerInset.height * 2
        let targetHeight = min(totalTextHeight, responseMaxHeight)

        if totalTextHeight >= responseMaxHeight {
            reachedMaxHeight = true
        }

        // Disable scrolling when all content fits within the visible area
        let contentFits = totalTextHeight <= responseMaxHeight
        responseScrollView.hasVerticalScroller = !contentFits

        // Skip no-op updates
        if abs(targetHeight - lastTargetHeight) < 1 { return }
        lastTargetHeight = targetHeight
        invalidateShadow()

        let newPanelHeight = inputHeight + 1 + targetHeight
        let newOriginY = topY - newPanelHeight
        let newFrame = NSRect(
            x: frame.origin.x,
            y: newOriginY,
            width: panelWidth,
            height: newPanelHeight
        )

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.responseHeightConstraint?.animator().constant = targetHeight
                self.animator().setFrame(newFrame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { [weak self] in
                    self?.positionMascotOverSpacer()
                }
            }
        } else {
            responseHeightConstraint?.constant = targetHeight
            setFrame(newFrame, display: false)
            positionMascotOverSpacer()
        }

        // Scroll to bottom as text streams in
        if autoScrollEnabled { scrollToBottomInstantly() }
    }

    /// Returns true if the scroll view is at or near the bottom (within 30px).
    private func isScrolledNearBottom() -> Bool {
        let contentHeight = responseScrollView.documentView?.frame.height ?? 0
        let visibleHeight = responseScrollView.contentView.bounds.height
        let scrollY = responseScrollView.contentView.bounds.origin.y
        // If content is shorter than visible area, consider it "at bottom"
        guard contentHeight > visibleHeight else { return true }
        return scrollY >= contentHeight - visibleHeight - 30
    }

    /// Scrolls to the bottom of the response only if the user hasn't scrolled up.
    private func scrollToBottomIfNeeded() {
        if isScrolledNearBottom() {
            scrollToBottomInstantly()
        }
    }

    /// Scrolls to the absolute bottom without any animation.
    private func scrollToBottomInstantly() {
        let clipView = responseScrollView.contentView
        let docHeight = responseTextView.frame.height
        let visibleHeight = clipView.bounds.height
        let targetY = max(0, docHeight - visibleHeight)
        // Use setBoundsOrigin for immediate, non-animated positioning
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        responseScrollView.reflectScrolledClipView(clipView)
        CATransaction.commit()
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
        rawMarkdown = ""
        pendingMarkdown = ""
        displayedMarkdown = ""
        conversationAttributed = NSMutableAttributedString()
        conversationBaseLength = 0
        characterQueue = []
        streamFinished = false
        lastRenderLength = 0
        lastTargetHeight = 0
        reachedMaxHeight = false
        autoScrollEnabled = true
        stopDisplayLink()
        stopCursorBlink()
        lastFrameTime = 0
        lastFullRenderTime = 0
        skeletonView.stopAnimating()
        skeletonView.isHidden = true
        responseTextView.textStorage?.setAttributedString(NSAttributedString())
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
        NSApp.activate()
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

// MARK: - Non-scrollable scroll view

/// NSScrollView subclass that blocks scroll wheel events when the content fits entirely
/// within the visible area, preventing unnecessary micro-scrolling.
private final class ConditionalScrollView: NSScrollView {
    /// Called when the user manually scrolls.
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return super.scrollWheel(with: event) }
        let contentHeight = documentView.frame.height
        let visibleHeight = contentView.bounds.height
        if contentHeight <= visibleHeight + 1 {
            // Content fits — don't scroll, pass event up the responder chain
            nextResponder?.scrollWheel(with: event)
        } else {
            // Detect user scrolling up
            if event.scrollingDeltaY > 0 {
                onUserScroll?()
            }
            super.scrollWheel(with: event)
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

// MARK: - Skeleton shimmer view

/// Displays 3 animated skeleton bars with a shimmer gradient, used as a loading placeholder.
private final class SkeletonView: NSView {
    private let barLayers: [CALayer] = {
        let widthFractions: [CGFloat] = [0.65, 0.85, 0.45]
        return widthFractions.map { _ in
            let layer = CALayer()
            layer.backgroundColor = NSColor(white: 0.25, alpha: 0.6).cgColor
            layer.cornerRadius = 6
            return layer
        }
    }()

    private let shimmerLayer: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor(white: 1.0, alpha: 0.15).cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [-1, -0.5, 0].map { NSNumber(value: $0) }
        return gradient
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in barLayers {
            layer?.addSublayer(bar)
        }
        layer?.addSublayer(shimmerLayer)
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = 12
        let spacing: CGFloat = 10
        let widthFractions: [CGFloat] = [0.65, 0.85, 0.45]

        for (i, bar) in barLayers.enumerated() {
            let y = CGFloat(i) * (barHeight + spacing)
            bar.frame = CGRect(
                x: 0,
                y: y,
                width: bounds.width * widthFractions[i],
                height: barHeight
            )
        }
        shimmerLayer.frame = bounds
    }

    func startAnimating() {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0].map { NSNumber(value: $0) }
        animation.toValue = [1.0, 1.5, 2.0].map { NSNumber(value: $0) }
        animation.duration = 1.2
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "shimmer")
    }

    func stopAnimating() {
        shimmerLayer.removeAnimation(forKey: "shimmer")
    }
}
