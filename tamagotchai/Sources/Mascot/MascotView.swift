import AppKit
import RiveRuntime
import SwiftUI

/// Manages a Rive-powered mascot that reacts to app state.
/// Uses the "Avatar 1" artboard from avatar_pack.riv with state machine "avatar".
/// Inputs: isHappy (Bool), isSad (Bool).
@MainActor
final class MascotView {
    private var currentState: MascotState = .idle
    private let riveViewModel: RiveViewModel
    private let mascotSize: CGFloat = 40

    /// Timer that cycles the avatar between states while typing.
    private var typingTimer: Timer?
    private var typingToggle = false

    /// A borderless child window that hosts the mascot via Metal/SwiftUI.
    let window: NSWindow

    init() {
        let vm = RiveViewModel(
            fileName: "avatar_pack",
            stateMachineName: "avatar",
            autoPlay: true,
            artboardName: "Avatar 1"
        )
        riveViewModel = vm

        let hostingView = NSHostingView(
            rootView: vm.view()
                .frame(width: 40, height: 40)
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = true
        win.contentView = hostingView
        window = win
    }

    // MARK: - State

    func setState(_ state: MascotState) {
        guard state != currentState else { return }
        currentState = state
        typingTimer?.invalidate()
        typingTimer = nil

        if state == .typing {
            startTypingCycle()
        } else {
            applyState()
        }
    }

    private func applyState() {
        switch currentState {
        case .idle:
            riveViewModel.setInput("isHappy", value: false)
            riveViewModel.setInput("isSad", value: false)
        case .typing:
            riveViewModel.setInput("isHappy", value: true)
            riveViewModel.setInput("isSad", value: false)
        case .waiting:
            riveViewModel.setInput("isHappy", value: false)
            riveViewModel.setInput("isSad", value: true)
        case .responding:
            riveViewModel.setInput("isSad", value: false)
            riveViewModel.setInput("isHappy", value: true)
        }
    }

    // MARK: - Typing cycle

    private func startTypingCycle() {
        typingToggle = true
        applyTypingToggle()

        typingTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, currentState == .typing else {
                self?.typingTimer?.invalidate()
                self?.typingTimer = nil
                return
            }
            typingToggle.toggle()
            applyTypingToggle()
        }
    }

    private func applyTypingToggle() {
        riveViewModel.setInput("isSad", value: false)
        riveViewModel.setInput("isHappy", value: typingToggle)
    }
}
