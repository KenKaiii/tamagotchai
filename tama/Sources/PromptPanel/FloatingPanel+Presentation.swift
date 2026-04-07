import AppKit
import os

private let panelLogger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "panel"
)

// MARK: - Restore Conversation

extension FloatingPanel {
    /// Restores a full conversation from saved messages into the response area.
    func restoreConversation(messages: [ChatMessage]) {
        isInsideSession = true

        // Re-enable adaptive color mapping (may have been disabled by showError)
        responseTextView.usesAdaptiveColorMappingForDarkAppearance = true

        // Reset streaming/conversation state
        rawMarkdown = ""
        pendingMarkdown = ""
        displayedMarkdown = ""
        conversationAttributed = NSMutableAttributedString()
        conversationBaseLength = 0
        characterQueue = []
        streamFinished = false
        typingFinished = false
        lastRenderLength = 0
        lastTargetHeight = 0
        reachedMaxHeight = false
        autoScrollEnabled = true
        stopDisplayLink()
        stopCursorBlink()
        responseTextView.removeAllCopyButtons()

        // Build the full conversation attributed string
        for message in messages {
            switch message.role {
            case .user:
                let text = message.content.compactMap { block -> String? in
                    if case let .text(t) = block { return t }
                    return nil
                }.joined()
                if !text.isEmpty {
                    conversationAttributed.append(makeUserBubble(text))
                }
            case .assistant:
                let text = message.content.compactMap { block -> String? in
                    if case let .text(t) = block { return t }
                    return nil
                }.joined()
                if !text.isEmpty {
                    conversationAttributed.append(MarkdownRenderer.render(text))
                }
            }
        }

        // If nothing displayable, show an empty state
        if conversationAttributed.length == 0 {
            let emptyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }(),
            ]
            conversationAttributed.append(
                NSAttributedString(string: "\nNo content in this session.", attributes: emptyAttrs)
            )
        }

        conversationBaseLength = conversationAttributed.length

        // Set the text storage
        responseTextView.textStorage?.setAttributedString(conversationAttributed)

        // Hide session list and tool list, show response area (keep tab bar visible for navigation)
        sessionListView.isHidden = true
        sessionListHeightConstraint?.constant = 0
        toolListView.isHidden = true
        toolListHeightConstraint?.constant = 0
        dividerContainer.isHidden = false
        responseScrollView.isHidden = false
        dividerContainer.alphaValue = 1
        responseScrollView.alphaValue = 1

        // Size the panel dynamically based on content
        responseTextView.layoutManager?.ensureLayout(
            for: responseTextView.textContainer!
        )
        let contentHeight = responseTextView.layoutManager?.usedRect(
            for: responseTextView.textContainer!
        ).height ?? 0
        let textInset = responseTextView.textContainerInset.height * 2
        let targetHeight = min(contentHeight + textInset, responseMaxHeight)

        if targetHeight >= responseMaxHeight {
            reachedMaxHeight = true
        }
        responseHeightConstraint?.constant = targetHeight
        responseScrollView.hasVerticalScroller = targetHeight >= responseMaxHeight
        lastTargetHeight = targetHeight

        // Account for tab bar if it's visible (e.g. navigating from session list)
        let tabBarExtra: CGFloat = tabBarContainer.isHidden ? 0 : tabBarHeight
        let panelHeight = inputHeight + 1 + tabBarExtra + targetHeight
        let newOriginY = topY - panelHeight
        setFrame(
            NSRect(x: frame.origin.x, y: newOriginY, width: panelWidth, height: panelHeight),
            display: true
        )

        // Force layout before positioning mascot so spacer has its final screen coordinates
        contentView?.layoutSubtreeIfNeeded()

        responseTextView.updateCodeBlockOverlays()
        positionMascotOverSpacer()
        invalidateShadow()
        scrollToBottomInstantly()
        makeFirstResponder(inputField)
        mascot.setState(.idle)

        // Large conversations may appear blank because the scroll view's clip view
        // hasn't fully laid out at the scroll offset yet. Deferring a second
        // scroll + display to the next run loop tick ensures the geometry is final.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scrollToBottomInstantly()
            responseScrollView.displayIfNeeded()
        }
    }
}

// MARK: - Voice Mode

extension FloatingPanel {
    /// Updates the audio waveform level during voice capture.
    func setAudioLevel(_ rms: Double) {
        guard isVoiceActivated else { return }
        audioWaveformView.setAudioLevel(rms)
    }

    /// Inserts transcribed voice text into the input field and scrolls to the end.
    func insertVoiceText(_ text: String) {
        inputField.stringValue = text
        // Scroll the field editor to the end so the latest dictated text is visible
        if let editor = inputField.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
        }
    }

    /// Hides the waveform after voice capture completes (entering response streaming).
    /// Keeps voice session active — placeholder stays voice-appropriate.
    func hideWaveform() {
        guard isVoiceActivated else { return }
        isVoiceActivated = false
        dismissWaveformWindow()
        // During voice session response, show empty placeholder (not "Ask anything")
        if isVoiceSession {
            inputField.placeholderString = ""
        }
    }

    /// Shows the voice UI — waveform visible, placeholder invites typing or speaking.
    func showVoiceFollowUp() {
        isVoiceActivated = true
        isVoiceSession = true
        inputField.placeholderString = "Type or say anything you like…"
        showWaveformWindow()
        makeFirstResponder(inputField)
    }

    /// Smoothly hides the waveform when the user starts typing during voice follow-up.
    func hideWaveformForTyping() {
        guard isVoiceActivated else { return }
        isVoiceActivated = false
        inputField.placeholderString = "Ask anything…"
        isVoiceSession = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.waveformWindow.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                dismissWaveformWindow()
                waveformWindow.alphaValue = 1
            }
        }
    }

    /// Ends the voice session entirely (panel dismiss or explicit stop).
    func endVoiceSession() {
        isVoiceActivated = false
        isVoiceSession = false
        dismissWaveformWindow()
        inputField.placeholderString = "Ask anything…"
    }
}

// MARK: - Waveform Window

extension FloatingPanel {
    func showWaveformWindow() {
        audioWaveformView.startAnimating()
        positionWaveformWindow()
        waveformWindow.alphaValue = 0
        addChildWindow(waveformWindow, ordered: .above)
        waveformWindow.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.waveformWindow.animator().alphaValue = 1
        }
    }

    func dismissWaveformWindow() {
        audioWaveformView.stopAnimating()
        removeChildWindow(waveformWindow)
        waveformWindow.orderOut(nil)
    }

    func positionWaveformWindow() {
        let waveformWidth: CGFloat = 120
        let waveformHeight: CGFloat = 24
        let gap: CGFloat = 6
        let x = frame.midX - waveformWidth / 2
        let y = frame.maxY + gap
        waveformWindow.setFrame(
            NSRect(x: x, y: y, width: waveformWidth, height: waveformHeight),
            display: true
        )
    }
}

// MARK: - Presentation

extension FloatingPanel {
    func present() {
        panelLogger.info("Panel presenting")
        isDismissing = false

        // Reset state
        if !isVoiceActivated {
            dismissWaveformWindow()
            inputField.placeholderString = "Ask anything…"
        }
        inputField.stringValue = ""
        rawMarkdown = ""
        pendingMarkdown = ""
        displayedMarkdown = ""
        conversationAttributed = NSMutableAttributedString()
        conversationBaseLength = 0
        characterQueue = []
        streamFinished = false
        typingFinished = false
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
        toolIndicatorView.isHidden = true
        toolIndicatorView.alphaValue = 0
        responseScrollView.contentInsets.bottom = 0
        responseTextView.textStorage?.setAttributedString(NSAttributedString())
        responseTextView.removeAllCopyButtons()
        dividerContainer.isHidden = true
        responseScrollView.isHidden = true
        responseHeightConstraint?.constant = 0
        sessionListView.isHidden = true
        sessionListView.alphaValue = 1
        sessionListHeightConstraint?.constant = 0

        // Reset tab bar to Chats
        tabBar.selectTab(0, animated: false)
        suppressHideSessionList = false

        // Reset tools, tasks, and search state
        isToolsMode = false
        isInsideTool = false
        isTasksMode = false
        isInsideTaskDetail = false
        isSessionSearchMode = false
        activeTool = nil
        if let activeToolView {
            mainStack.removeArrangedSubview(activeToolView)
            activeToolView.removeFromSuperview()
            activeToolHeightConstraint = nil
            self.activeToolView = nil
        }
        toolListView.isHidden = true
        toolListHeightConstraint?.constant = 0

        mascot.setState(.idle)
        mascot.resume()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame

        let originX = screenFrame.midX - panelWidth / 2
        // Position so the fully-expanded panel (input + divider + tab bar + response)
        // would be vertically centered on screen. The panel grows downward from topY.
        let fullExpandedHeight = inputHeight + 1 + tabBarHeight + responseMaxHeight
        topY = screenFrame.midY + fullExpandedHeight / 2

        let panelFrame = NSRect(
            x: originX,
            y: topY - inputHeight,
            width: panelWidth,
            height: inputHeight
        )
        setFrame(panelFrame, display: true)

        alphaValue = 0
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            makeFirstResponder(inputField)
        }

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
    func positionMascotOverSpacer() {
        let spacerInWindow = mascotSpacer.convert(mascotSpacer.bounds, to: nil)
        let spacerOnScreen = convertToScreen(spacerInWindow)
        mascot.window.setFrameOrigin(spacerOnScreen.origin)
    }

    func dismiss() {
        guard !isDismissing else { return }
        panelLogger.info("Panel dismissing")
        isDismissing = true
        endVoiceSession()
        mascot.pause()
        onDismiss?()

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
