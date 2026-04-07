import AppKit

// MARK: - Code block copy button

/// A glassmorphism "Copy" text button overlaid on code blocks,
/// matching the GlassButton style used elsewhere in the app.
final class CodeBlockCopyButton: NSView {
    var codeString: String = ""

    private static let defaultTitle = "Copy"
    private static let copiedTitle = "Copied"
    private static let buttonHeight: CGFloat = 22
    private static let horizontalPadding: CGFloat = 10
    private static let cornerRadius: CGFloat = 6
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: defaultTitle)
        field.font = font
        field.textColor = NSColor.white.withAlphaComponent(0.85)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isSelectable = false
        return field
    }()

    private var isHovered = false

    override init(frame _: NSRect) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.buttonHeight),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        sizeToContent()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func sizeToContent() {
        let textSize = (label.stringValue as NSString).size(withAttributes: [.font: Self.font])
        let width = ceil(textSize.width) + Self.horizontalPadding * 2
        frame.size = NSSize(width: width, height: Self.buttonHeight)
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
    }

    override func mouseDown(with _: NSEvent) {
        ButtonSound.shared.play()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(codeString, forType: .string)

        label.stringValue = Self.copiedTitle
        label.textColor = NSColor.systemGreen
        sizeToContent()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.label.stringValue = Self.defaultTitle
            self?.label.textColor = NSColor.white.withAlphaComponent(0.85)
            self?.sizeToContent()
        }
    }
}

// MARK: - Response text view

/// Collected info about a single code block for drawing.
private struct CodeBlockInfo {
    var rect: NSRect
    var language: String
    var glyphRange: NSRange
}

/// NSTextView subclass that draws rounded-rect backgrounds behind code blocks
/// and manages copy button overlays.
final class ResponseTextView: NSTextView {
    private static let headerHeight: CGFloat = 28
    private static let blockCornerRadius: CGFloat = 8
    private var copyButtons: [CodeBlockCopyButton] = []

    /// Called when the user clicks an inline image attachment. The argument is the image URL string.
    var onImageClicked: ((String) -> Void)?

    // MARK: - Image hover overlay

    private lazy var imageHoverOverlay: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        view.layer?.opacity = 0
        return view
    }()

    private var currentHoverURL: String?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove old areas tagged as ours.
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        if let url = imageURL(at: event.locationInWindow) {
            if url != currentHoverURL {
                showImageHover(at: event.locationInWindow)
                currentHoverURL = url
            }
            NSCursor.pointingHand.set()
        } else if currentHoverURL != nil {
            hideImageHover()
            currentHoverURL = nil
            NSCursor.arrow.set()
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if currentHoverURL != nil {
            hideImageHover()
            currentHoverURL = nil
            NSCursor.arrow.set()
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let url = imageURL(at: event.locationInWindow) {
            onImageClicked?(url)
            return
        }
        super.mouseDown(with: event)
    }

    /// Shows the hover overlay on the image attachment at the given window point.
    private func showImageHover(at windowPoint: NSPoint) {
        guard let rect = imageRect(at: windowPoint) else { return }

        if imageHoverOverlay.superview == nil {
            addSubview(imageHoverOverlay)
        }
        imageHoverOverlay.frame = rect.insetBy(dx: 1, dy: 1)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageHoverOverlay.animator().alphaValue = 1
        }
    }

    /// Hides the hover overlay with a fade-out animation.
    private func hideImageHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            imageHoverOverlay.animator().alphaValue = 0
        }
    }

    /// Returns the bounding rect (in view coordinates) of the image attachment
    /// at the given window point, or nil if none.
    private func imageRect(at windowPoint: NSPoint) -> NSRect? {
        guard let storage = textStorage,
              let layoutMgr = layoutManager,
              let textCont = textContainer,
              storage.length > 0
        else { return nil }

        let point = convert(windowPoint, from: nil)
        let idx = characterIndexForInsertion(at: point)

        // Find the character index that has the .imageURL attribute.
        let charIdx: Int? = if idx < storage.length,
                               storage.attribute(.imageURL, at: idx, effectiveRange: nil) != nil
        {
            idx
        } else if idx > 0,
                  storage.attribute(.imageURL, at: idx - 1, effectiveRange: nil) != nil
        {
            idx - 1
        } else {
            nil
        }

        guard let ci = charIdx else { return nil }

        let glyphRange = layoutMgr.glyphRange(
            forCharacterRange: NSRange(location: ci, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutMgr.boundingRect(forGlyphRange: glyphRange, in: textCont)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// Returns the `.imageURL` attribute at the given window-coordinate point,
    /// checking both the character at the insertion index and the one before it
    /// (the insertion point sits between characters, so a click on the right
    /// half of an attachment returns the index *after* it).
    private func imageURL(at windowPoint: NSPoint) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(windowPoint, from: nil)
        let idx = characterIndexForInsertion(at: point)

        // Check the character at idx.
        if idx < storage.length,
           let url = storage.attribute(.imageURL, at: idx, effectiveRange: nil) as? String
        {
            return url
        }
        // Check the character just before idx (handles right-half clicks).
        if idx > 0,
           let url = storage.attribute(.imageURL, at: idx - 1, effectiveRange: nil) as? String
        {
            return url
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let storage = textStorage,
              let layoutMgr = layoutManager,
              let textCont = textContainer
        else {
            super.draw(dirtyRect)
            return
        }

        let blocks = collectCodeBlocks(
            storage: storage, layoutMgr: layoutMgr, textCont: textCont
        )
        for block in blocks {
            drawCodeBlock(block)
        }
        super.draw(dirtyRect)
    }

    // MARK: - Code block collection

    private func collectCodeBlocks(
        storage: NSTextStorage,
        layoutMgr: NSLayoutManager,
        textCont: NSTextContainer
    ) -> [CodeBlockInfo] {
        let fullRange = NSRange(location: 0, length: storage.length)
        let origin = textContainerOrigin
        var blocks: [CodeBlockInfo] = []

        storage.enumerateAttribute(
            .codeBlockContent, in: fullRange, options: []
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutMgr.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil
            )
            var bounding = layoutMgr.boundingRect(forGlyphRange: glyphRange, in: textCont)
            bounding.origin.x += origin.x
            bounding.origin.y += origin.y

            let inset = textContainerInset.width
            let rect = NSRect(
                x: inset, y: bounding.origin.y - 4,
                width: bounds.width - inset * 2, height: bounding.height + 8
            )
            let language = (storage.attribute(
                .codeBlockLanguage, at: range.location, effectiveRange: nil
            ) as? String) ?? ""

            if var last = blocks.last, rect.minY <= last.rect.maxY + 2 {
                last.rect = last.rect.union(rect)
                if last.language.isEmpty, !language.isEmpty { last.language = language }
                let start = min(last.glyphRange.location, glyphRange.location)
                let end = max(NSMaxRange(last.glyphRange), NSMaxRange(glyphRange))
                last.glyphRange = NSRange(location: start, length: end - start)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(CodeBlockInfo(
                    rect: rect, language: language, glyphRange: glyphRange
                ))
            }
        }
        return blocks
    }

    // MARK: - Code block drawing

    private func drawCodeBlock(_ block: CodeBlockInfo) {
        let hdr = Self.headerHeight

        // Extend rect upward by header height
        let blockRect = NSRect(
            x: block.rect.origin.x, y: block.rect.origin.y - hdr,
            width: block.rect.width, height: block.rect.height + hdr
        )

        let bgPath = NSBezierPath(
            roundedRect: blockRect,
            xRadius: Self.blockCornerRadius, yRadius: Self.blockCornerRadius
        )

        // Body background
        NSColor(white: 0.12, alpha: 0.55).setFill()
        bgPath.fill()

        // Header bar (clipped to rounded corners)
        let headerRect = NSRect(
            x: blockRect.minX, y: blockRect.minY,
            width: blockRect.width, height: hdr
        )
        NSGraphicsContext.saveGraphicsState()
        bgPath.addClip()
        NSColor(white: 0.18, alpha: 0.5).setFill()
        NSBezierPath(rect: headerRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Separator
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: blockRect.minX, y: blockRect.minY + hdr))
        sep.line(to: NSPoint(x: blockRect.maxX, y: blockRect.minY + hdr))
        sep.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.1).setStroke()
        sep.stroke()

        // Language label
        if !block.language.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ]
            let size = (block.language as NSString).size(withAttributes: attrs)
            (block.language as NSString).draw(
                at: NSPoint(
                    x: blockRect.minX + 10,
                    y: blockRect.minY + (hdr - size.height) / 2
                ),
                withAttributes: attrs
            )
        }

        // Border
        NSColor.white.withAlphaComponent(0.1).setStroke()
        bgPath.lineWidth = 0.5
        bgPath.stroke()
    }

    /// Removes all copy button overlays. Call when resetting the text view
    /// (e.g. on new chat) to avoid stale buttons lingering over empty content.
    func removeAllCopyButtons() {
        for button in copyButtons {
            button.removeFromSuperview()
        }
        copyButtons.removeAll()
    }

    /// Creates, repositions, or removes copy button overlays
    /// to match current code blocks.
    func updateCodeBlockOverlays() {
        guard let storage = textStorage,
              let layoutMgr = layoutManager,
              let textCont = textContainer
        else { return }

        let hdr = Self.headerHeight
        let blocks = collectCodeBlocks(
            storage: storage, layoutMgr: layoutMgr, textCont: textCont
        )

        // Remove excess buttons
        while copyButtons.count > blocks.count {
            copyButtons.removeLast().removeFromSuperview()
        }

        // Create/reuse buttons — positioned in the header bar
        for (idx, block) in blocks.enumerated() {
            let button: CodeBlockCopyButton
            if idx < copyButtons.count {
                button = copyButtons[idx]
            } else {
                button = CodeBlockCopyButton()
                copyButtons.append(button)
                addSubview(button)
            }
            button.codeString = (textStorage?.attribute(
                .codeBlockContent,
                at: layoutMgr.characterIndexForGlyph(at: block.glyphRange.location),
                effectiveRange: nil
            ) as? String) ?? ""
            // Header sits above the text bounding rect
            let headerTopY = block.rect.minY - hdr
            button.frame.origin = NSPoint(
                x: block.rect.maxX - button.frame.width - 8,
                y: headerTopY + (hdr - button.frame.height) / 2
            )
        }
    }
}
