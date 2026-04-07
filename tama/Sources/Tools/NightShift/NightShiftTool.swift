import AppKit
import os

/// Toggle tool that enables/disables Night Shift via the private CoreBrightness framework.
/// Uses `CBBlueLightClient` loaded at runtime to avoid linking against private APIs.
@MainActor
final class NightShiftTool: TogglePanelTool {
    let id = "night-shift"
    let name = "Night Shift"
    let icon = "moon.fill"
    let toolDescription = "Warm your display colors"
    let shortcutHint: String? = nil

    var onStateChanged: (() -> Void)?

    private(set) var isEnabled = false

    private static let logger = Logger(
        subsystem: "com.unstablemind.tama",
        category: "tool.nightshift"
    )

    // MARK: - CoreBrightness runtime bridge (loaded lazily)

    private static var clientLoaded = false
    private static var blueLightClient: NSObject?

    /// Whether the hardware supports Night Shift (Blue Light Reduction).
    static var isSupported: Bool {
        ensureClient()
        guard let cls = NSClassFromString("CBBlueLightClient") else { return false }
        let sel = NSSelectorFromString("supportsBlueLightReduction")
        guard (cls as AnyObject).responds(to: sel) else { return true }
        typealias SupportsFn = @convention(c) (AnyObject, Selector) -> Bool
        let imp = unsafeBitCast((cls as AnyObject).method(for: sel), to: SupportsFn.self)
        return imp(cls as AnyObject, sel)
    }

    private static func ensureClient() {
        guard !clientLoaded else { return }
        clientLoaded = true

        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY
        ) != nil else {
            logger.error("Failed to load CoreBrightness framework")
            return
        }
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            logger.error("CBBlueLightClient class not found")
            return
        }
        blueLightClient = cls.init()
    }

    func toggle() {
        Self.ensureClient()
        let newState = !isEnabled
        Self.setNightShift(enabled: newState)
        // Update optimistically — the system needs time to propagate the change
        isEnabled = newState
        onStateChanged?()
        Self.logger.info("Night Shift \(newState ? "enabled" : "disabled")")

        // Verify after the system has had time to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let actual = Self.readCurrentState()
            if actual != isEnabled {
                isEnabled = actual
                onStateChanged?()
                Self.logger.warning("Night Shift state mismatch — corrected to \(actual)")
            }
        }
    }

    // MARK: - Private helpers

    private static func readCurrentState() -> Bool {
        guard let client = blueLightClient else { return false }
        var statusBytes = [UInt8](repeating: 0, count: 512)
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: sel) else { return false }

        typealias GetStatusFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<UInt8>) -> Bool
        let imp = unsafeBitCast(
            (client as AnyObject).method(for: sel),
            to: GetStatusFn.self
        )
        let ok = imp(client, sel, &statusBytes)
        guard ok else { return false }
        // The enabled flag is at byte offset 1 on macOS 26
        return statusBytes[1] != 0
    }

    private static func setNightShift(enabled: Bool) {
        guard let client = blueLightClient else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard client.responds(to: sel) else {
            logger.error("CBBlueLightClient does not respond to setEnabled:")
            return
        }
        typealias SetEnabledFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let imp = unsafeBitCast(
            (client as AnyObject).method(for: sel),
            to: SetEnabledFn.self
        )
        _ = imp(client, sel, enabled)
    }
}
