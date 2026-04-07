import AppKit

// MARK: - Non-scrollable scroll view

/// NSScrollView subclass that blocks scroll wheel events when the content fits entirely
/// within the visible area, preventing unnecessary micro-scrolling.
final class ConditionalScrollView: NSScrollView {
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
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - White cursor text field

/// NSTextField subclass that sets the insertion point (cursor) color to white.
final class WhiteCursorTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let fieldEditor = currentEditor() as? NSTextView {
            fieldEditor.insertionPointColor = .white
        }
        return result
    }
}
