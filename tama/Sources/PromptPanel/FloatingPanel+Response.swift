import AppKit
import os

private let panelLogger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "panel"
)

// Response rendering, streaming, display-link typing animation, and scroll management.
extension FloatingPanel {
    // MARK: - Response

    /// Shows a styled error block in the response area with a tinted background, bold title, and message.
    func showError(title: String, message: String, tint: NSColor) {
        // Prevent hideSessionList from running (it races with this method)
        suppressHideSessionList = true

        // Instantly clear session/tool lists, keep tab bar + divider visible
        sessionListView.isHidden = true
        sessionListView.alphaValue = 1
        sessionListHeightConstraint?.constant = 0
        toolListView.isHidden = true
        toolListHeightConstraint?.constant = 0
        dividerContainer.isHidden = false
        dividerContainer.alphaValue = 1
        tabBarContainer.isHidden = false
        tabBarContainer.alphaValue = 1

        let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let messageFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        let textColor = NSColor.white

        // Wrap in a rounded-rect background using NSTextBlock
        let errorBlock = ErrorTextBlock(tint: tint)
        let blockStyle = NSMutableParagraphStyle()
        blockStyle.textBlocks = [errorBlock]
        blockStyle.lineSpacing = 4
        blockStyle.paragraphSpacingBefore = 8

        let wrapped = NSMutableAttributedString()

        // Use a single paragraph with line break so NSTextBlock wraps both lines
        let titleStr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: titleFont,
                .foregroundColor: textColor,
            ]
        )
        let msgStr = NSMutableAttributedString(
            string: "\n" + message,
            attributes: [
                .font: messageFont,
                .foregroundColor: textColor.withAlphaComponent(0.85),
            ]
        )
        wrapped.append(titleStr)
        wrapped.append(msgStr)
        wrapped.addAttribute(
            .paragraphStyle, value: blockStyle,
            range: NSRange(location: 0, length: wrapped.length)
        )
        // NSTextBlock needs a trailing newline to close the block
        let resetStyle = NSMutableParagraphStyle()
        resetStyle.paragraphSpacingBefore = 0
        resetStyle.paragraphSpacing = 0
        wrapped.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: messageFont,
                .paragraphStyle: resetStyle,
            ]
        ))

        // Separate spacer paragraph OUTSIDE the NSTextBlock for gap between errors
        let spacerStyle = NSMutableParagraphStyle()
        spacerStyle.minimumLineHeight = 12
        spacerStyle.maximumLineHeight = 12
        wrapped.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 1),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: spacerStyle,
            ]
        ))

        // Commit the error block into the conversation so subsequent messages
        // append correctly rather than overlapping.
        conversationAttributed.append(wrapped)
        conversationBaseLength = conversationAttributed.length

        // Stop any in-progress streaming state
        streamFinished = true
        typingFinished = true
        reachedMaxHeight = false
        lastTargetHeight = 0
        stopDisplayLink()
        stopCursorBlink()
        pendingMarkdown = ""
        displayedMarkdown = ""
        rawMarkdown = ""

        // Disable adaptive color mapping so white text stays white on the dark panel
        responseTextView.usesAdaptiveColorMappingForDarkAppearance = false

        // Update text storage to the full conversation (including error)
        if let storage = responseTextView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(conversationAttributed)
            storage.endEditing()
        }

        // Show and size the response area
        dividerContainer.isHidden = false
        responseScrollView.isHidden = false
        dividerContainer.alphaValue = 1
        responseScrollView.alphaValue = 1
        tabBarContainer.isHidden = false
        tabBarContainer.alphaValue = 1

        // Force layout so we get accurate text height measurement
        contentView?.layoutSubtreeIfNeeded()
        responseTextView.layoutManager?.ensureLayout(for: responseTextView.textContainer!)
        let contentHeight = responseTextView.layoutManager?.usedRect(
            for: responseTextView.textContainer!
        ).height ?? 0
        let textInset = responseTextView.textContainerInset.height * 2
        let targetHeight = min(contentHeight + textInset, responseMaxHeight)

        responseHeightConstraint?.constant = targetHeight
        lastTargetHeight = targetHeight

        let tabBarExtra: CGFloat = tabBarContainer.isHidden ? 0 : tabBarHeight
        let panelHeight = inputHeight + 1 + tabBarExtra + targetHeight
        let newOriginY = topY - panelHeight
        setFrame(
            NSRect(x: frame.origin.x, y: newOriginY, width: panelWidth, height: panelHeight),
            display: true
        )

        contentView?.layoutSubtreeIfNeeded()
        positionMascotOverSpacer()
        invalidateShadow()
        scrollToBottomInstantly()
        makeFirstResponder(inputField)
        suppressHideSessionList = false
    }

    /// Captures the current input text, clears the field, and returns what was typed.
    /// Call this immediately on submit so the user can start typing their next prompt.
    func consumeInput() -> String {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        inputField.stringValue = ""
        return text
    }

    /// Streams text deltas into the response area with smooth character-by-character typing.
    /// Returns the full assistant response text for conversation history tracking.
    @discardableResult
    func streamResponse(_ stream: AsyncThrowingStream<String, Error>, userText: String = "") async throws -> String {
        isInsideSession = true

        // Re-enable adaptive color mapping (may have been disabled by showError)
        responseTextView.usesAdaptiveColorMappingForDarkAppearance = true

        // Build user bubble attributed string before appending
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
        typingFinished = false
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
        let qEmpty = characterQueue.isEmpty
        let tFinished = typingFinished
        panelLogger.debug(
            "streamFinished=true queueEmpty=\(qEmpty) receivedFirst=\(receivedFirst) typingFinished=\(tFinished)"
        )

        // If we never received any text, clean up skeleton
        if !receivedFirst {
            skeletonView.stopAnimating()
            skeletonView.isHidden = true
        }

        // Safety: if the character queue already drained before streamFinished
        // was set, the display link won't call finishTyping. Force it now.
        if characterQueue.isEmpty, receivedFirst {
            panelLogger.debug("Safety net: calling finishTyping from streamResponse")
            finishTyping()
        }

        return pendingMarkdown
    }

    // MARK: - User Bubble

    /// Creates a right-aligned chat bubble attributed string for the user's message.
    func makeUserBubble(_ text: String) -> NSAttributedString {
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
            conversationAttributed.length > 0 ? 14 : 0
        style.paragraphSpacing = 14

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

    // MARK: - Text Measurement

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

    // MARK: - Display Link & Cursor

    // Starts a display link that drives the typing animation in sync with the display refresh rate.
    private func startDisplayLink() {
        stopDisplayLink()
        lastFrameTime = CACurrentMediaTime()
        lastFullRenderTime = lastFrameTime
        guard let view = contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(displayLinkCallback))
        link.add(to: .main, forMode: .common)
        displayLink = link
        startCursorBlink()
    }

    @objc private func displayLinkCallback() {
        displayLinkFired()
    }

    // Stops and releases the display link.
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Starts the cursor blink timer (~2 blinks per second).
    private func startCursorBlink() {
        cursorVisible = true
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.cursorVisible.toggle()
                self.renderDisplayedMarkdown()
            }
        }
        RunLoop.main.add(cursorBlinkTimer!, forMode: .common)
    }

    /// Stops the cursor blink and hides the cursor.
    func stopCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorVisible = false
    }

    // MARK: - Typing Animation

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
        let alreadyDone = typingFinished
        panelLogger.debug("finishTyping called, typingFinished=\(alreadyDone)")
        guard !typingFinished else { return }
        typingFinished = true
        panelLogger.debug("finishTyping executing — stopping cursor")
        stopDisplayLink()
        stopCursorBlink()
        // Strip any cursor glyph that may have leaked into pendingMarkdown
        let cleanMarkdown = pendingMarkdown
            .replacingOccurrences(of: Self.streamingCursorGlyph, with: "")
        pendingMarkdown = cleanMarkdown
        rawMarkdown = cleanMarkdown
        // Commit assistant response into conversation attributed
        let rendered = MarkdownRenderer.render(cleanMarkdown)
        conversationAttributed.append(rendered)
        // Update base length BEFORE render so the tail replace doesn't wipe it
        conversationBaseLength = conversationAttributed.length
        displayedMarkdown = ""
        // Force text storage to exactly match conversationAttributed (no tail)
        if let storage = responseTextView.textStorage {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            storage.beginEditing()
            storage.setAttributedString(conversationAttributed)
            storage.endEditing()
            CATransaction.commit()
        }
        responseTextView.updateCodeBlockOverlays()
        updateHeight(animated: true)
        mascot.setState(.idle)
        // Refocus input for follow-up, preserving any text typed during the response
        let existingText = inputField.stringValue
        if existingText.isEmpty {
            makeFirstResponder(inputField)
        } else {
            // Avoid makeFirstResponder which resets the field editor and selects all.
            // The input is already first responder from the initial submit, so just
            // ensure the cursor is at the end with no selection.
            if let editor = inputField.currentEditor() {
                editor.selectedRange = NSRange(location: existingText.count, length: 0)
            }
        }
    }

    // MARK: - Rendering

    /// Re-renders displayedMarkdown into the text view.
    /// Cursor glyph is always present during streaming (layout-stable) with color toggled for blink.
    private func renderDisplayedMarkdown() {
        guard let storage = responseTextView.textStorage else { return }

        let isStreaming = !streamFinished
        let textToRender = isStreaming
            ? displayedMarkdown + Self.streamingCursorGlyph
            : displayedMarkdown

        let rendered = MarkdownRenderer.render(textToRender)

        // Toggle cursor color (visible ↔ transparent) instead of adding/removing the glyph
        let finalRendered: NSAttributedString
        if isStreaming, rendered.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: rendered)
            let str = mutable.string as NSString
            let cursorRange = str.range(of: Self.streamingCursorGlyph, options: .backwards)
            if cursorRange.location != NSNotFound {
                let color: NSColor = cursorVisible ? .labelColor : .labelColor.withAlphaComponent(0)
                mutable.addAttribute(.foregroundColor, value: color, range: cursorRange)
            }
            finalRendered = mutable
        } else {
            finalRendered = rendered
        }

        // Replace only the streaming tail — leave conversation history untouched
        let tailRange = NSRange(
            location: conversationBaseLength,
            length: storage.length - conversationBaseLength
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        storage.beginEditing()
        storage.replaceCharacters(in: tailRange, with: finalRendered)
        storage.endEditing()
        CATransaction.commit()

        // Auto-scroll to keep latest content visible
        if autoScrollEnabled {
            scrollToBottomInstantly()
        }
    }

    // MARK: - Height Management

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

        let tabBarExtra: CGFloat = tabBarContainer.isHidden ? 0 : tabBarHeight
        let newPanelHeight = inputHeight + 1 + tabBarExtra + targetHeight
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

    // MARK: - Scrolling

    /// Scrolls to the absolute bottom without any animation.
    func scrollToBottomInstantly() {
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
}
