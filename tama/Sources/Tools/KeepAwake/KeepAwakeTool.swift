import IOKit.pwr_mgt
import os

/// Toggle tool that prevents the Mac from sleeping using an IOKit power assertion.
/// Uses `IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep`
/// to prevent both display and idle sleep in-process (no child process needed).
@MainActor
final class KeepAwakeTool: TogglePanelTool {
    let id = "keep-awake"
    let name = "Keep Awake"
    let icon = "cup.and.heat.waves.fill"
    let toolDescription = "Prevent your Mac from sleeping"
    let shortcutHint: String? = nil

    var onStateChanged: (() -> Void)?

    private(set) var isEnabled = false
    private var assertionID: IOPMAssertionID = 0

    private static let logger = Logger(
        subsystem: "com.unstablemind.tama",
        category: "tool.keepawake"
    )

    func toggle() {
        if isEnabled {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Tama Keep Awake" as CFString,
            &assertionID
        )
        let aid = assertionID
        if result == kIOReturnSuccess {
            isEnabled = true
            onStateChanged?()
            Self.logger.info("Keep Awake enabled (assertionID: \(aid))")
        } else {
            Self.logger.error("Failed to create power assertion: \(result)")
        }
    }

    private func stop() {
        let aid = assertionID
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            Self.logger.info("Keep Awake disabled (assertionID: \(aid))")
        } else {
            Self.logger.error("Failed to release power assertion: \(result)")
        }
        assertionID = 0
        isEnabled = false
        onStateChanged?()
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
