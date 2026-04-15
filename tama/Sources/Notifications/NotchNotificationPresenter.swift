import AppKit
import AVFoundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "notch"
)

/// A displayed notification with its metadata.
private struct DisplayedNotification {
    let id: UUID
    let panel: NSPanel
    let shapeLayer: CAShapeLayer?
    let contentLayer: CALayer?
    let timer: Timer?
    let title: String
    let body: String
    let isNotchShaped: Bool
    let onTap: () -> Void
}

/// Presents notifications that visually extend from the Mac's hardware notch.
///
/// The first (topmost) notification uses a notch-shaped black window that blends seamlessly
/// with the physical notch and expands outward with a spring animation. Additional notifications
/// stack below as standard rounded rectangles.
///
/// On non-notch displays, falls back to a centered rounded rectangle at menu bar height.
@MainActor
enum NotchNotificationPresenter {
    /// Currently visible notifications, ordered from newest (index 0) to oldest.
    private static var activeNotifications: [DisplayedNotification] = []

    /// Audio player for the notification sound.
    private static var audioPlayer: AVAudioPlayer?

    /// The full title of the current top notification (for detail view).
    private(set) static var currentTitle: String = ""

    /// The full body of the current top notification (for detail view).
    private(set) static var currentBody: String = ""

    /// Maximum number of notifications to show simultaneously.
    private static let maxVisibleNotifications = 5

    /// Vertical spacing between stacked notifications.
    private static let stackSpacing: CGFloat = 8

    // MARK: - Notch Shape Constants

    /// Expanded toast width for the notch-shaped notification.
    private static let expandedWidth: CGFloat = 380

    /// Expanded toast height for the notch-shaped notification.
    private static let expandedHeight: CGFloat = 100

    /// Top corner radius when collapsed (matching hardware notch curvature).
    private static let closedTopRadius: CGFloat = 6

    /// Bottom corner radius when collapsed.
    private static let closedBottomRadius: CGFloat = 10

    /// Top corner radius when expanded.
    private static let expandedTopRadius: CGFloat = 14

    /// Bottom corner radius when expanded.
    private static let expandedBottomRadius: CGFloat = 20

    /// Shadow padding added around the expanded notch shape (sides and bottom only).
    private static let shadowPadding: CGFloat = 20

    // MARK: - Fallback (non-notch) Constants

    private static let fallbackToastWidth: CGFloat = 340
    private static let fallbackCornerRadius: CGFloat = 16

    // MARK: - Animation

    private static let expandDuration: TimeInterval = 0.45
    private static let collapseDuration: TimeInterval = 0.25

    // MARK: - Public API

    /// Show a reminder notification.
    static func showReminder(name: String, message: String) {
        logger.info("Showing toast reminder: '\(name)'")
        showToast(
            title: name,
            subtitle: message,
            duration: 5
        )
    }

    /// Show an agent reply notification (when panel was dismissed during processing).
    /// - Parameters:
    ///   - message: The reply text to display.
    ///   - onTap: Custom tap handler. When nil, tapping opens the detail modal.
    static func showAgentReply(message: String, onTap: (() -> Void)? = nil) {
        logger.info("Showing toast agent reply")
        showToast(
            title: "Tama",
            subtitle: message,
            duration: 6,
            customOnTap: onTap
        )
    }

    /// Show a routine result notification.
    static func showRoutineResult(name: String, result: String) {
        logger.info("Showing toast routine result: '\(name)'")
        showToast(
            title: name,
            subtitle: result,
            duration: 6
        )
    }

    /// Show multiple notifications simultaneously (for testing batch display).
    static func showBatch(count: Int, prefix: String = "Test") {
        logger.info("Showing batch of \(count) notifications simultaneously")
        for i in 1 ... count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i - 1) * 0.15) {
                showToast(
                    title: "\(prefix) #\(i) of \(count)",
                    subtitle: "Notification \(i) in batch of \(count)",
                    duration: 6
                )
            }
        }
    }

    /// Clear all notification panels and reset state.
    static func clearAll() {
        logger.info("Clearing all notifications (\(activeNotifications.count) active)")
        for notification in activeNotifications {
            notification.timer?.invalidate()
            notification.panel.orderOut(nil)
        }
        activeNotifications.removeAll()
    }

    /// Dismiss all notifications immediately without animation.
    static func clearQueue() {
        clearAll()
    }

    /// Handles a click on a toast.
    static func handleTap(for notificationId: UUID) {
        guard let notification = activeNotifications.first(where: { $0.id == notificationId }) else { return }
        notification.onTap()
    }

    // MARK: - Private Implementation

    private static func showToast(
        title: String,
        subtitle: String,
        duration: TimeInterval,
        customOnTap: (() -> Void)? = nil
    ) {
        NotchOverlayTracker.overlayDidShow()
        playNotificationSound()

        guard let screen = NSScreen.main else { return }

        // Remove oldest if at max capacity.
        if activeNotifications.count >= maxVisibleNotifications {
            removeOldestNotification()
        }

        let isFirstNotification = activeNotifications.isEmpty
        let notificationID = UUID()

        if isFirstNotification {
            showNotchNotification(
                id: notificationID,
                screen: screen,
                title: title,
                subtitle: subtitle,
                duration: duration,
                customOnTap: customOnTap
            )
        } else {
            showStackedNotification(
                id: notificationID,
                screen: screen,
                title: title,
                subtitle: subtitle,
                duration: duration,
                customOnTap: customOnTap
            )
        }

        // Update current title/body to top notification.
        currentTitle = title
        currentBody = subtitle
    }

    /// Show the primary notch-shaped notification that extends from the hardware notch.
    private static func showNotchNotification(
        id: UUID,
        screen: NSScreen,
        title: String,
        subtitle: String,
        duration: TimeInterval,
        customOnTap: (() -> Void)? = nil
    ) {
        let notchSize = screen.notchSize
        let screenFrame = screen.frame

        // Window size: large enough to hold the expanded state plus shadow padding on sides/bottom.
        // No padding at the top — the shape must be flush with screen.frame.maxY.
        let windowWidth = expandedWidth + shadowPadding * 2
        let windowHeight = expandedHeight + shadowPadding

        // Position: top-center, top edge exactly at screen top.
        let originX = screenFrame.midX - windowWidth / 2
        let originY = screenFrame.maxY - windowHeight

        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        // Root view with clear background — the notch shape provides the visible area.
        // Geometry is flipped so y=0 is at the top (matching screen top / notch position).
        let rootView = FlippedLayerView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        // Notch shape layer: black fill clipped to the notch silhouette.
        let shapeLayer = CAShapeLayer()
        shapeLayer.fillColor = NSColor.black.cgColor

        // Start with collapsed (notch-sized) shape.
        let closedRect = closedNotchRect(
            windowSize: NSSize(width: windowWidth, height: windowHeight),
            notchSize: notchSize
        )
        shapeLayer.path = NotchShapePath.path(
            in: closedRect,
            topCornerRadius: closedTopRadius,
            bottomCornerRadius: closedBottomRadius
        )
        shapeLayer.frame = rootView.bounds
        rootView.layer?.addSublayer(shapeLayer)

        // 1px black bridge line at the top to eliminate any subpixel gap with the hardware notch.
        let bridgeLayer = CALayer()
        bridgeLayer.backgroundColor = NSColor.black.cgColor
        bridgeLayer.frame = CGRect(
            x: closedRect.origin.x + closedTopRadius,
            y: 0,
            width: closedRect.width - closedTopRadius * 2,
            height: 1
        )
        rootView.layer?.addSublayer(bridgeLayer)

        // Shadow (only visible when expanded).
        shapeLayer.shadowColor = NSColor.black.cgColor
        shapeLayer.shadowOpacity = 0
        shapeLayer.shadowRadius = 12
        shapeLayer.shadowOffset = CGSize(width: 0, height: 4)

        // Content view: holds title, subtitle — initially hidden, fades in on expand.
        // Positioned below the notch area so text doesn't overlap the hardware notch.
        // Clipped to the notch shape so nothing overflows.
        let contentView = buildContentView(title: title, subtitle: subtitle)
        let expandedRect = expandedNotchRect(windowSize: NSSize(width: windowWidth, height: windowHeight))
        let contentInset = expandedTopRadius + expandedBottomRadius
        contentView.frame = NSRect(
            x: expandedRect.origin.x + contentInset,
            y: notchSize.height,
            width: expandedRect.width - contentInset * 2,
            height: expandedRect.height - notchSize.height - expandedBottomRadius
        )
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.alphaValue = 0
        rootView.addSubview(contentView)

        // Click overlay covers the entire window area.
        let overlay = ToastOverlayView(frame: rootView.bounds, notificationId: id)
        overlay.autoresizingMask = [.width, .height]
        rootView.addSubview(overlay)

        panel.contentView = rootView
        panel.orderFrontRegardless()

        // Create timer for auto-dismiss.
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                dismissNotification(id: id)
            }
        }

        let tapHandler = {
            dismissNotification(id: id)
            if let customOnTap {
                customOnTap()
            } else {
                NotificationDetailPanel.show(title: title, body: subtitle)
            }
        }

        let displayed = DisplayedNotification(
            id: id,
            panel: panel,
            shapeLayer: shapeLayer,
            contentLayer: contentView.layer,
            timer: timer,
            title: title,
            body: subtitle,
            isNotchShaped: true,
            onTap: tapHandler
        )
        activeNotifications.insert(displayed, at: 0)

        // Animate: expand from notch size to full size.
        animateExpand(
            shapeLayer: shapeLayer,
            contentView: contentView,
            windowSize: NSSize(width: windowWidth, height: windowHeight)
        )
    }

    /// Show a secondary stacked notification below the notch notification.
    private static func showStackedNotification(
        id: UUID,
        screen: NSScreen,
        title: String,
        subtitle: String,
        duration: TimeInterval,
        customOnTap: (() -> Void)? = nil
    ) {
        let contentView = buildContentView(title: title, subtitle: subtitle)
        let contentSize = contentView.fittingSize
        let toastHeight = max(contentSize.height, 64)
        let toastWidth = fallbackToastWidth

        let screenFrame = screen.frame
        let originX = screenFrame.midX - toastWidth / 2

        // Stack below the notch notification and any existing stacked notifications.
        let stackIndex = activeNotifications.count
        let notchBottom = screenFrame.maxY - expandedHeight - shadowPadding
        let offsetY = CGFloat(stackIndex - 1) * (toastHeight + stackSpacing)
        let visibleY = notchBottom - toastHeight - stackSpacing - offsetY
        let hiddenY = screenFrame.maxY + 50

        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: hiddenY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)

        // Wrapper view with solid black background matching the notch aesthetic.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NSColor.black.cgColor
        wrapper.layer?.cornerRadius = fallbackCornerRadius
        wrapper.layer?.masksToBounds = true
        wrapper.layer?.borderWidth = 0.5
        wrapper.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        contentView.frame = NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight)
        wrapper.addSubview(contentView)

        let overlay = ToastOverlayView(frame: wrapper.bounds, notificationId: id)
        overlay.autoresizingMask = [.width, .height]
        wrapper.addSubview(overlay)

        panel.contentView = wrapper
        panel.orderFrontRegardless()

        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                dismissNotification(id: id)
            }
        }

        let tapHandler = {
            dismissNotification(id: id)
            if let customOnTap {
                customOnTap()
            } else {
                NotificationDetailPanel.show(title: title, body: subtitle)
            }
        }

        let displayed = DisplayedNotification(
            id: id,
            panel: panel,
            shapeLayer: nil,
            contentLayer: nil,
            timer: timer,
            title: title,
            body: subtitle,
            isNotchShaped: false,
            onTap: tapHandler
        )
        activeNotifications.insert(displayed, at: 0)

        // Animate slide-down.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: originX, y: visibleY, width: toastWidth, height: toastHeight),
                display: true
            )
        }

        updateStackPositions()
    }

    // MARK: - Notch Rect Calculation

    /// The collapsed notch rect within the window coordinate space (matches hardware notch).
    /// With flipped geometry: y=0 is the top of the window (= top of the screen).
    /// The notch shape starts at y=0 so its flat top is flush with the screen edge.
    private static func closedNotchRect(windowSize: NSSize, notchSize: NSSize) -> CGRect {
        let x = (windowSize.width - notchSize.width) / 2
        return CGRect(x: x, y: 0, width: notchSize.width, height: notchSize.height)
    }

    /// The expanded notch rect within the window coordinate space.
    /// Starts at y=0 (top) with shadow padding on the sides and bottom only.
    private static func expandedNotchRect(windowSize: NSSize) -> CGRect {
        let x = shadowPadding
        let width = windowSize.width - shadowPadding * 2
        let height = windowSize.height - shadowPadding
        return CGRect(x: x, y: 0, width: width, height: height)
    }

    // MARK: - Animation

    /// Animate the notch shape from collapsed to expanded.
    private static func animateExpand(
        shapeLayer: CAShapeLayer,
        contentView: NSView,
        windowSize: NSSize
    ) {
        let expandedRect = expandedNotchRect(windowSize: windowSize)
        let expandedPath = NotchShapePath.path(
            in: expandedRect,
            topCornerRadius: expandedTopRadius,
            bottomCornerRadius: expandedBottomRadius
        )

        // Animate shape path.
        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = shapeLayer.path
        pathAnimation.toValue = expandedPath
        pathAnimation.damping = 14
        pathAnimation.stiffness = 180
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "expandPath")
        shapeLayer.path = expandedPath

        // Animate shadow appearing.
        let shadowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnimation.fromValue = 0
        shadowAnimation.toValue = Float(0.5)
        shadowAnimation.duration = expandDuration
        shadowAnimation.isRemovedOnCompletion = false
        shadowAnimation.fillMode = .forwards
        shapeLayer.add(shadowAnimation, forKey: "shadowIn")
        shapeLayer.shadowOpacity = 0.5

        // Fade in content after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().alphaValue = 1.0
            }
        }
    }

    /// Animate the notch shape from expanded back to collapsed, then remove.
    private static func animateCollapse(
        notification: DisplayedNotification,
        screen: NSScreen
    ) {
        guard let shapeLayer = notification.shapeLayer else {
            // Stacked notification — simple slide up.
            let frame = notification.panel.frame
            let targetY = screen.frame.maxY + 50
            NSAnimationContext.runAnimationGroup { context in
                context.duration = collapseDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                notification.panel.animator().alphaValue = 0
                notification.panel.animator().setFrame(
                    NSRect(x: frame.origin.x, y: targetY, width: frame.width, height: frame.height),
                    display: true
                )
            } completionHandler: {
                MainActor.assumeIsolated {
                    notification.panel.orderOut(nil)
                }
            }
            return
        }

        let windowSize = notification.panel.frame.size
        let notchSize = screen.notchSize
        let closedRect = closedNotchRect(windowSize: windowSize, notchSize: notchSize)
        let closedPath = NotchShapePath.path(
            in: closedRect,
            topCornerRadius: closedTopRadius,
            bottomCornerRadius: closedBottomRadius
        )

        // Fade out content first.
        if let contentView = notification.panel.contentView?.subviews.first(where: { !($0 is ToastOverlayView) }) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                contentView.animator().alphaValue = 0
            }
        }

        // Collapse shape back to notch size.
        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = shapeLayer.path
        pathAnimation.toValue = closedPath
        pathAnimation.damping = 18
        pathAnimation.stiffness = 220
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "collapsePath")
        shapeLayer.path = closedPath

        // Remove shadow.
        let shadowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnimation.fromValue = shapeLayer.shadowOpacity
        shadowAnimation.toValue = Float(0)
        shadowAnimation.duration = collapseDuration
        shadowAnimation.isRemovedOnCompletion = false
        shadowAnimation.fillMode = .forwards
        shapeLayer.add(shadowAnimation, forKey: "shadowOut")
        shapeLayer.shadowOpacity = 0

        // After collapse, fade out and remove window.
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                notification.panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    notification.panel.orderOut(nil)
                }
            }
        }
    }

    // MARK: - Dismiss

    /// Dismiss a specific notification by ID.
    private static func dismissNotification(id: UUID) {
        guard let index = activeNotifications.firstIndex(where: { $0.id == id }) else { return }

        NotchOverlayTracker.overlayDidHide()
        let notification = activeNotifications.remove(at: index)
        notification.timer?.invalidate()

        guard let screen = NSScreen.main else {
            notification.panel.orderOut(nil)
            updateStackPositions()
            return
        }

        animateCollapse(notification: notification, screen: screen)

        // Update current title/body to next notification.
        if let top = activeNotifications.first {
            currentTitle = top.title
            currentBody = top.body
        }

        updateStackPositions()
    }

    /// Remove the oldest notification (called when at max capacity).
    private static func removeOldestNotification() {
        guard let oldest = activeNotifications.last else { return }
        dismissNotification(id: oldest.id)
    }

    /// Update positions of stacked (non-notch) notifications.
    private static func updateStackPositions() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let originX = screenFrame.midX - fallbackToastWidth / 2
        let notchBottom = screenFrame.maxY - expandedHeight - shadowPadding

        // Only reposition non-notch-shaped notifications (stacked ones).
        var stackIndex = 0
        for notification in activeNotifications {
            guard !notification.isNotchShaped else { continue }

            let panel = notification.panel
            let currentFrame = panel.frame
            let toastHeight = currentFrame.height

            let offsetY = CGFloat(stackIndex) * (toastHeight + stackSpacing)
            let visibleY = notchBottom - toastHeight - stackSpacing - offsetY

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(
                    NSRect(x: originX, y: visibleY, width: fallbackToastWidth, height: toastHeight),
                    display: true
                )
            }

            stackIndex += 1
        }
    }

    // MARK: - Sound

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

    // MARK: - Content Builder

    private static func buildContentView(
        title: String,
        subtitle: String
    ) -> NSView {
        // The container uses manual frame positioning (not Auto Layout) so it
        // must not have translatesAutoresizingMaskIntoConstraints set to false.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        // Title — single line, truncated.
        let titleField = NSTextField(labelWithString: title)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.9)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        container.addSubview(titleField)

        // Subtitle — max 2 lines, truncated to stay within the notch.
        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleField.textColor = NSColor.white.withAlphaComponent(0.7)
        subtitleField.maximumNumberOfLines = 2
        subtitleField.lineBreakMode = .byTruncatingTail
        container.addSubview(subtitleField)

        let padding: CGFloat = 14

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: padding - 4),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
        ])

        return container
    }
}

// MARK: - Toast Overlay View

/// Transparent overlay that captures mouse clicks and hover events on the toast.
private final class ToastOverlayView: NSView {
    private var trackingArea: NSTrackingArea?
    private let notificationId: UUID

    init(frame: NSRect, notificationId: UUID = UUID()) {
        self.notificationId = notificationId
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        notificationId = UUID()
        super.init(coder: coder)
    }

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
    }

    override func mouseExited(with _: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with _: NSEvent) {
        ButtonSound.shared.play()
        NotchNotificationPresenter.handleTap(for: notificationId)
    }
}

// MARK: - Flipped Layer View

/// An `NSView` whose backing layer uses flipped geometry (y=0 at top, increasing downward).
/// This matches how the notch shape path is drawn and ensures the flat top edge
/// aligns with the top of the window (= top of the screen = hardware notch).
private final class FlippedLayerView: NSView {
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        return layer
    }
}
