import AppKit
import Carbon.HIToolbox
import os

/// Manages the floating prompt panel lifecycle and global hotkey registration.
@MainActor
final class PromptPanelController {
    static let shared = PromptPanelController()
    private let logger = Logger(subsystem: "com.unstablemind.tamagotchai", category: "hotkey")

    private var panel: FloatingPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // MARK: - Public

    /// Registers the global hotkey.
    /// Default shortcut: ⌥ + Space (Option + Space).
    func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey)
    ) {
        registerCarbonHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Unregisters the hotkey and cleans up.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Toggles the panel visibility.
    func toggle() {
        if let panel, panel.isVisible {
            panel.dismiss()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        if panel == nil {
            let newPanel = FloatingPanel()
            newPanel.onSubmit = { [weak self] text in
                self?.handleSubmit(text)
            }
            newPanel.onTextChanged = { [weak newPanel] text in
                if text.isEmpty {
                    newPanel?.mascot.setState(.idle)
                } else {
                    newPanel?.mascot.notifyKeystroke()
                }
            }
            panel = newPanel
        }

        panel?.present()
    }

    private func handleSubmit(_ text: String) {
        // Set mascot to waiting state
        panel?.mascot.setState(.waiting)

        // Placeholder response — will be replaced with AI backend.
        let lines = (1 ... 30).map { "Line \($0): Response to \"\(text)\"" }
        let response = "You asked: \"\(text)\"\n\n"
            + lines.joined(separator: "\n")
            + "\n\nEnd of response. Scroll up to see more."

        // Simulate a brief wait, then show response
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self else { return }
            panel?.mascot.setState(.responding)
            panel?.showResponse(response)

            // After response is shown, settle back to idle
            try? await Task.sleep(for: .seconds(4.0))
            guard panel?.mascot.currentState == .responding else { return }
            panel?.mascot.setState(.idle)
        }
    }

    // MARK: - Carbon Hot Key

    private func registerCarbonHotKey(keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(
            signature: fourCharCode("TGCH"),
            id: 1
        )

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in
                    PromptPanelController.shared.toggle()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        guard handlerResult == noErr else {
            logger.error("Failed to install hotkey handler")
            return
        }

        let registerResult = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerResult != noErr {
            logger.error("Failed to register hotkey")
        }
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}
