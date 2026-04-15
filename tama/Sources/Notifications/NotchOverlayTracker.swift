import Foundation

/// Tracks how many notch overlays (notifications, activity indicators) are
/// currently displayed. NotchCallButton and NotchCallTimer observe these
/// notifications to hide/show themselves so they don't overlap.
///
/// Uses a debounce on the "inactive" post so brief gaps between overlays
/// (e.g. activity indicator → notification transition) don't cause a flash.
@MainActor
enum NotchOverlayTracker {
    private static var overlayCount = 0

    /// Debounce timer — delays posting `.notchOverlayInactive` so brief gaps
    /// between consecutive overlays don't cause the call wings to flash.
    private static var debounceTimer: Timer?

    /// How long to wait after the last overlay hides before declaring inactive.
    private static let debounceDelay: TimeInterval = 0.4

    /// Call when a notch overlay (notification, activity indicator) appears.
    static func overlayDidShow() {
        // Cancel any pending inactive debounce — a new overlay appeared.
        debounceTimer?.invalidate()
        debounceTimer = nil

        overlayCount += 1
        if overlayCount == 1 {
            NotificationCenter.default.post(name: .notchOverlayActive, object: nil)
        }
    }

    /// Call when a notch overlay disappears.
    static func overlayDidHide() {
        overlayCount = max(0, overlayCount - 1)
        if overlayCount == 0 {
            // Debounce — wait a beat before declaring inactive, in case another
            // overlay is about to appear (e.g. notification following activity indicator).
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { _ in
                MainActor.assumeIsolated {
                    // Re-check — another overlay may have appeared during the delay.
                    guard overlayCount == 0 else { return }
                    NotificationCenter.default.post(name: .notchOverlayInactive, object: nil)
                }
            }
        }
    }

    /// Whether any overlay is currently active (or debounce is pending).
    static var isActive: Bool { overlayCount > 0 || debounceTimer != nil }
}

extension Notification.Name {
    /// Posted when the first notch overlay appears — call wings should hide.
    static let notchOverlayActive = Notification.Name("notchOverlayActive")

    /// Posted when the last notch overlay disappears — call wings can reappear.
    static let notchOverlayInactive = Notification.Name("notchOverlayInactive")
}
