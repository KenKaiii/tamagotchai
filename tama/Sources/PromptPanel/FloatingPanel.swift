import AppKit
import os

private let panelLogger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "panel"
)

// A borderless, floating NSPanel that mimics macOS Spotlight's window behavior.
// - Appears centered on the active screen
// - Floats above all windows
// - Dismisses when focus is lost or Escape is pressed
// - Grows downward from a fixed top edge when content expands
final class FloatingPanel: NSPanel, NSTextFieldDelegate {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The panel width.
    let panelWidth: CGFloat = 680

    /// The input bar height.
    let inputHeight: CGFloat = 58

    /// Max height for the response area.
    let responseMaxHeight: CGFloat = 400

    /// The stored top edge so the panel grows downward, not upward.
    var topY: CGFloat = 0

    /// Tracks whether we're currently dismissing to avoid re-entrant calls.
    var isDismissing = false

    /// When true, `resignKey()` will not dismiss the panel (e.g. image preview is open).
    var isShowingImagePreview = false

    /// Raw markdown text accumulated during streaming.
    var rawMarkdown = ""

    // MARK: - Character queue streaming

    /// Characters waiting to be "typed" onto screen.
    var characterQueue: [Character] = []

    /// The markdown text displayed so far (typed out character by character).
    var displayedMarkdown = ""

    /// Full raw text received from API so far.
    var pendingMarkdown = ""

    /// Accumulated attributed string from all previous conversation turns.
    var conversationAttributed = NSMutableAttributedString()

    /// Length of conversation history in the text storage (streaming appends after this).
    var conversationBaseLength = 0

    /// Blinking cursor glyph shown at the end of streaming text.
    static let streamingCursorGlyph = "▍"

    /// Whether the streaming cursor is currently visible (toggles for blink effect).
    var cursorVisible = true

    /// Timer that toggles the cursor blink state.
    var cursorBlinkTimer: Timer?

    /// Display link that drives the typing animation in sync with the screen refresh rate.
    var displayLink: CADisplayLink?

    /// Whether finishTyping has already been called for the current response.
    var typingFinished = false

    /// Timestamp of the last display link frame (for calculating elapsed time).
    var lastFrameTime: CFTimeInterval = 0

    /// Timestamp of the last full markdown re-render.
    var lastFullRenderTime: CFTimeInterval = 0

    /// Whether the stream has finished delivering all deltas.
    var streamFinished = false

    /// Length of displayedMarkdown at last markdown re-render.
    var lastRenderLength = 0

    /// Last computed target height to skip no-op updates.
    var lastTargetHeight: CGFloat = 0

    /// Whether auto-scroll is active. Disabled when user scrolls up, re-enabled on new message.
    var autoScrollEnabled = true

    /// Once the panel reaches max height, it stays there for the session.
    var reachedMaxHeight = false

    /// When true, hideSessionList becomes a no-op. Set before showError
    /// to prevent the animated hide from collapsing the panel.
    var suppressHideSessionList = false

    /// Whether the panel was activated by voice (shows waveform).
    var isVoiceActivated = false

    /// Whether the session was started via voice (persists across capture/response cycles).
    var isVoiceSession = false

    /// Audio waveform view shown floating above the panel during voice mode.
    lazy var audioWaveformView: AudioWaveformView = {
        let v = AudioWaveformView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// Child window that hosts the waveform above the panel (no background).
    lazy var waveformWindow: NSWindow = {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.level = .floating
        w.ignoresMouseEvents = true
        w.contentView = audioWaveformView
        audioWaveformView.frame = w.contentView!.bounds
        audioWaveformView.autoresizingMask = [.width, .height]
        audioWaveformView.isHidden = false
        return w
    }()

    /// Tool activity indicator shown during tool execution.
    lazy var toolIndicatorView: ToolIndicatorView = {
        let v = ToolIndicatorView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// Skeleton shimmer view shown while waiting for first token.
    lazy var skeletonView: SkeletonView = {
        let v = SkeletonView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// The session history list shown when the panel opens.
    /// Custom animated tab bar with a sliding highlight indicator.
    lazy var tabBar: AnimatedTabBar = {
        let bar = AnimatedTabBar(
            labels: ["Chats", "Reminders", "Routines", "Tasks", "Tools"]
        ) { [weak self] index in
            self?.tabBarChanged(index)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    /// Container for the tab bar so we can show/hide it as a group with consistent padding.
    lazy var tabBarContainer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
            tabBar.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            tabBar.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
        ])
        return v
    }()

    lazy var sessionListView: SessionListView = {
        let v = SessionListView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.onSelectSession = { [weak self] session in
            self?.onSelectSession?(session)
        }
        v.onDeleteSession = { [weak self] session in
            self?.onDeleteSession?(session)
        }
        return v
    }()

    /// Height constraint for the session list.
    var sessionListHeightConstraint: NSLayoutConstraint?

    /// Height constraint for the response scroll view.
    var responseHeightConstraint: NSLayoutConstraint?

    // MARK: - Tools Mode

    /// The tool list view shown when the Tools tab is active.
    lazy var toolListView: ToolListView = {
        let v = ToolListView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.onSelectTool = { [weak self] tool in
            self?.onToolSelected?(tool)
        }
        return v
    }()

    /// Height constraint for the tool list.
    var toolListHeightConstraint: NSLayoutConstraint?

    /// Whether the panel is currently in Tools mode (Tools tab selected).
    var isToolsMode = false

    /// Whether we're currently viewing a specific tool's drilled-in UI.
    var isInsideTool = false

    /// Whether we're currently viewing a session's conversation (chat/reminder/routine).
    var isInsideSession = false

    // MARK: - Tasks Mode

    /// The task list view shown when the Tasks tab is active.
    lazy var taskListView: TaskListView = {
        let v = TaskListView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.onSelectTaskList = { [weak self] taskList in
            self?.onSelectTaskList?(taskList)
        }
        v.onDeleteTaskList = { [weak self] taskList in
            self?.onDeleteTaskList?(taskList)
        }
        return v
    }()

    /// Height constraint for the task list.
    var taskListHeightConstraint: NSLayoutConstraint?

    /// The detail view for a single task list (when drilled in).
    var taskDetailView: TaskDetailView?

    /// Height constraint for the task detail view.
    var taskDetailHeightConstraint: NSLayoutConstraint?

    /// Whether the panel is currently in Tasks mode (Tasks tab selected).
    var isTasksMode = false

    /// Whether we're currently viewing a task list's detail (drilled in).
    var isInsideTaskDetail = false

    /// The currently active tool (when drilled in).
    var activeTool: PanelTool?

    /// The view pushed by the active tool.
    var activeToolView: NSView?

    /// Height constraint for the active tool view.
    var activeToolHeightConstraint: NSLayoutConstraint?

    // MARK: - Callbacks

    /// Called when the user presses Return in the text field.
    var onSubmit: ((String) -> Void)?

    /// Called when the user types in the input field.
    var onTextChanged: ((String) -> Void)?

    /// Called when the panel is dismissed (Escape, focus loss, etc.).
    var onDismiss: (() -> Void)?

    /// Called when the user presses Escape while agent is active — interrupt, don't dismiss.
    var onInterrupt: (() -> Bool)?

    /// Called when the user selects a session from the history list.
    var onSelectSession: ((ChatSession) -> Void)?

    /// Called when the user deletes a session from the history list.
    var onDeleteSession: ((ChatSession) -> Void)?

    /// Called when the user changes the session list tab.
    var onTabChanged: ((SessionTab) -> Void)?

    /// Called when ESC is pressed inside a session to navigate back to the list.
    var onBackToList: (() -> Void)?

    /// Called when the user selects a tool from the tool list.
    var onToolSelected: ((PanelTool) -> Void)?

    /// Called when the input field text changes while in Tools mode.
    var onToolSearchChanged: ((String) -> Void)?

    /// Called when the input field text changes while in Tasks mode.
    var onTaskSearchChanged: ((String) -> Void)?

    /// Called when the input field text changes while in a session-list search tab (reminders/routines).
    var onSessionSearchChanged: ((String) -> Void)?

    /// Whether the session list is in search/filter mode (reminders or routines tab, not drilled in).
    var isSessionSearchMode = false

    /// Called when the user selects a task list from the task list.
    var onSelectTaskList: ((TaskList) -> Void)?

    /// Called when the user deletes a task list from the task list.
    var onDeleteTaskList: ((TaskList) -> Void)?

    // MARK: - UI Components

    /// The animated mascot inline in the input row.
    let mascot = MascotView()

    lazy var inputField: NSTextField = {
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
    lazy var mascotSpacer: NSView = {
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

    lazy var dividerContainer: NSView = {
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
    lazy var responseTextView: ResponseTextView = {
        let textView = ResponseTextView()
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
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.autoresizingMask = [.width]
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.onImageClicked = { [weak self] url in
            self?.showImagePreview(for: url)
        }
        return textView
    }()

    /// The scroll view wrapping the response text.
    lazy var responseScrollView: ConditionalScrollView = {
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

    lazy var mainStack: NSStackView = {
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
        hidesOnDeactivate = false
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

        // Add divider + tab bar + session list + tool list + response to stack, keep them hidden
        mainStack.addArrangedSubview(dividerContainer)
        mainStack.addArrangedSubview(tabBarContainer)
        mainStack.addArrangedSubview(sessionListView)
        mainStack.addArrangedSubview(toolListView)
        mainStack.addArrangedSubview(taskListView)
        mainStack.addArrangedSubview(responseScrollView)

        let sessionHeight = sessionListView.heightAnchor.constraint(equalToConstant: 0)
        sessionHeight.isActive = true
        sessionListHeightConstraint = sessionHeight

        let toolListHeight = toolListView.heightAnchor.constraint(equalToConstant: 0)
        toolListHeight.isActive = true
        toolListHeightConstraint = toolListHeight

        let taskListHeight = taskListView.heightAnchor.constraint(equalToConstant: 0)
        taskListHeight.isActive = true
        taskListHeightConstraint = taskListHeight

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

        // Add tool activity indicator floating over the response area.
        // Added to container (above backgroundView/mainStack) so it's always visible.
        container.addSubview(toolIndicatorView)
        NSLayoutConstraint.activate([
            toolIndicatorView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            toolIndicatorView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
    }

    /// Extra bottom content inset added when the tool indicator is visible
    /// so the streaming cursor / last line is never hidden behind the floating pill.
    private let toolIndicatorBottomInset: CGFloat = 36

    /// The intrinsic height of the tab bar container (top padding + control + bottom padding).
    let tabBarHeight: CGFloat = 44

    private func tabBarChanged(_ index: Int) {
        ButtonSound.shared.play()
        let tab = SessionTab(rawValue: index) ?? .chats
        onTabChanged?(tab)
    }

    // MARK: - Tool Indicator

    func showToolIndicator(name: String, args: [String: String] = [:]) {
        toolIndicatorView.show(toolName: name, args: args)
        responseScrollView.contentInsets.bottom = toolIndicatorBottomInset
    }

    func hideToolIndicator() {
        toolIndicatorView.hide()
        responseScrollView.contentInsets.bottom = 0
    }

    // MARK: - Dismiss on Escape

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            // If inside a task detail view, pop back to task list
            if isInsideTaskDetail {
                popTaskDetail()
                return
            }
            // If inside a tool's drilled-in view, pop back to tool list
            if isInsideTool {
                popToolView()
                return
            }
            // Try interrupt first — if something was interrupted, don't dismiss
            if onInterrupt?() == true {
                return
            }
            // If inside a session (chat/reminder/routine), go back to the list
            if isInsideSession {
                onBackToList?()
                return
            }
            dismiss()
            return
        }
        super.sendEvent(event)
    }

    // MARK: - Dismiss on focus loss

    override func resignKey() {
        guard !isShowingImagePreview else { return }
        // Skip super to avoid AppKit's inactive window styling flash before our fade-out.
        dismiss()
    }

    // MARK: - Image Preview

    private var imagePreviewPanel: ImagePreviewPanel?

    func showImagePreview(for urlString: String) {
        guard let image = ImageCache.load(from: urlString) else { return }

        // Derive a short title from the file name
        let fileName = (urlString as NSString).lastPathComponent
        let title = fileName.isEmpty ? "Image Preview" : fileName

        isShowingImagePreview = true

        let preview = ImagePreviewPanel(image: image, title: title)
        preview.onDismiss = { [weak self] in
            self?.dismissImagePreview()
        }
        preview.center()
        preview.makeKeyAndOrderFront(nil)
        imagePreviewPanel = preview
    }

    func dismissImagePreview() {
        if let preview = imagePreviewPanel {
            preview.orderOut(nil)
            imagePreviewPanel = nil
        }
        isShowingImagePreview = false
        makeKeyAndOrderFront(nil)
    }

    // MARK: - NSTextFieldDelegate — Return key

    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // In tools mode, Return does nothing (filtering is live)
            if isToolsMode, !isInsideTool { return true }
            // In tasks mode (list view), Return does nothing (filtering is live)
            if isTasksMode, !isInsideTaskDetail { return true }
            // In session search mode (reminders/routines list), Return does nothing
            if isSessionSearchMode { return true }
            // Inside a tool, Return is consumed (tool handles its own interaction)
            if isInsideTool { return true }

            let text = inputField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return true }
            onSubmit?(text)
            return true
        }
        return false
    }
}
