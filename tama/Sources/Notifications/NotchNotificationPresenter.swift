import AppKit
import AVFoundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "notch"
)

/// Presents glassmorphism toast notifications that slide down from the top-center of the screen.
@MainActor
enum NotchNotificationPresenter {
    /// The currently visible toast panel, if any.
    private static var activePanel: NSPanel?

    /// Auto-dismiss timer for the current toast.
    private static var dismissTimer: Timer?

    /// Audio player for the notification sound.
    private static var audioPlayer: AVAudioPlayer?

    /// Called when the user clicks the toast.
    private static var onTap: (() -> Void)?

    /// The full title of the current notification (for detail view).
    private(set) static var currentTitle: String = ""

    /// The full body of the current notification (for detail view).
    private(set) static var currentBody: String = ""

    /// Remaining dismiss time when hover pauses the timer.
    private static var remainingDismissTime: TimeInterval = 0

    /// When the dismiss timer was last started/resumed.
    private static var timerStartDate: Date?

    /// Show a reminder notification.
    static func showReminder(name: String, message: String) {
        logger.info("Presenting toast reminder: '\(name)'")
        showToast(
            icon: "bell.fill",
            iconColor: .systemYellow,
            title: name,
            subtitle: message,
            duration: 5
        )
    }

    /// Show an agent reply notification (when panel was dismissed during processing).
    static func showAgentReply(message: String) {
        logger.info("Presenting toast agent reply")
        showToast(
            icon: "bubble.left.fill",
            iconColor: .systemPurple,
            title: "Tama",
            subtitle: message,
            duration: 6
        )
    }

    /// Show a routine result notification.
    static func showRoutineResult(name: String, result: String) {
        logger.info("Presenting toast routine result: '\(name)'")
        showToast(
            icon: "bolt.fill",
            iconColor: .systemTeal,
            title: name,
            subtitle: result,
            duration: 6
        )
    }

    // MARK: - Private

    private static let toastWidth: CGFloat = 340
    private static let toastCornerRadius: CGFloat = 16
    private static let slideInDuration: TimeInterval = 0.3
    private static let slideOutDuration: TimeInterval = 0.15

    private static func showToast(
        icon: String,
        iconColor: NSColor,
        title: String,
        subtitle: String,
        duration: TimeInterval
    ) {
        // Dismiss any existing toast immediately.
        dismissImmediately()

        playNotificationSound()

        guard let screen = NSScreen.main else { return }

        // Build content view.
        let contentView = buildContentView(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle)
        let contentSize = contentView.fittingSize
        let toastHeight = max(contentSize.height, 48)

        // Position: top-center, just below the safe area (notch).
        let safeTop = screen.safeAreaInsets.top
        let screenFrame = screen.frame
        let originX = screenFrame.midX - toastWidth / 2
        // Start off-screen (above top edge) for slide-down animation.
        let hiddenY = screenFrame.maxY
        let visibleY = screenFrame.maxY - safeTop - toastHeight - 8

        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: hiddenY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        // Clear wrapper so the window itself is fully transparent.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NSColor.clear.cgColor

        // Glass background.
        let effectView = NSVisualEffectView(frame: wrapper.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = toastCornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        // Add content on top of the effect view.
        contentView.frame = NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight)
        effectView.addSubview(contentView)

        wrapper.addSubview(effectView)
        panel.contentView = wrapper
        panel.orderFrontRegardless()

        activePanel = panel
        currentTitle = title
        currentBody = subtitle

        // Add click gesture and hover tracking via a transparent overlay.
        let overlay = ToastOverlayView(frame: effectView.bounds)
        overlay.autoresizingMask = [.width, .height]
        effectView.addSubview(overlay)

        onTap = {
            dismissImmediately()
            NotificationDetailPanel.show(title: title, body: subtitle)
        }

        // Animate slide-down.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = slideInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: originX, y: visibleY, width: toastWidth, height: toastHeight),
                display: true
            )
        }

        // Schedule auto-dismiss.
        remainingDismissTime = duration
        timerStartDate = Date()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                dismissAnimated()
            }
        }
    }

    private static func dismissAnimated() {
        guard let panel = activePanel else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let screen = NSScreen.main else {
            dismissImmediately()
            return
        }

        let frame = panel.frame
        let targetY = screen.frame.maxY

        NSAnimationContext.runAnimationGroup { context in
            context.duration = slideOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(
                NSRect(x: frame.origin.x, y: targetY, width: frame.width, height: frame.height),
                display: true
            )
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
                if activePanel === panel {
                    activePanel = nil
                }
            }
        }
    }

    private static func dismissImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        activePanel?.orderOut(nil)
        activePanel = nil
        onTap = nil
    }

    /// Pauses the auto-dismiss timer (called on mouse hover).
    static func pauseDismissTimer() {
        guard let timer = dismissTimer, timer.isValid, let startDate = timerStartDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        remainingDismissTime = max(0.5, remainingDismissTime - elapsed)
        timer.invalidate()
        dismissTimer = nil
        logger.debug("Dismiss timer paused, remaining: \(remainingDismissTime)s")
    }

    /// Resumes the auto-dismiss timer (called on mouse exit).
    static func resumeDismissTimer() {
        guard dismissTimer == nil, activePanel != nil else { return }
        timerStartDate = Date()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: remainingDismissTime, repeats: false) { _ in
            Task { @MainActor in
                dismissAnimated()
            }
        }
        logger.debug("Dismiss timer resumed for \(remainingDismissTime)s")
    }

    /// Handles a click on the toast.
    static func handleTap() {
        onTap?()
    }

    private static func playNotificationSound() {
        guard let url = Bundle.main.url(forResource: "notification", withExtension: "mp3") else {
            logger.warning("Notification sound file not found in bundle")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.6
            player.play()
            audioPlayer = player
        } catch {
            logger.error("Failed to play notification sound: \(error.localizedDescription)")
        }
    }

    private static func buildContentView(
        icon: String,
        iconColor: NSColor,
        title: String,
        subtitle: String
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Icon
        let iconImageView = NSImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        if let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            iconImageView.image = iconImage.withSymbolConfiguration(config)
        }
        iconImageView.contentTintColor = iconColor
        iconImageView.setContentHuggingPriority(.required, for: .horizontal)
        iconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(iconImageView)

        // Title
        let titleField = NSTextField(labelWithString: title)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.9)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        container.addSubview(titleField)

        // Subtitle
        let subtitleField = NSTextField(wrappingLabelWithString: subtitle)
        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleField.textColor = NSColor.white.withAlphaComponent(0.7)
        subtitleField.maximumNumberOfLines = 5
        subtitleField.lineBreakMode = .byWordWrapping
        subtitleField.preferredMaxLayoutWidth = toastWidth - 56
        container.addSubview(subtitleField)

        let padding: CGFloat = 14

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            iconImageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),

            titleField.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            subtitleField.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -padding),
        ])

        return container
    }
}

// MARK: - Toast Overlay View

/// Transparent overlay that captures mouse clicks and hover events on the toast.
private final class ToastOverlayView: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        NSCursor.pointingHand.push()
        NotchNotificationPresenter.pauseDismissTimer()
    }

    override func mouseExited(with _: NSEvent) {
        NSCursor.pop()
        NotchNotificationPresenter.resumeDismissTimer()
    }

    override func mouseDown(with _: NSEvent) {
        ButtonSound.shared.play()
        NotchNotificationPresenter.handleTap()
    }
}
