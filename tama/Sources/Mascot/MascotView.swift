import AppKit
import os
import RiveRuntime
import SwiftUI

private let mascotLogger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "mascot"
)

/// Manages a Rive-powered mascot that reacts to app state.
/// Uses the "Avatar 1" artboard from avatar_pack.riv with state machine "avatar".
/// Inputs: isHappy (Bool), isSad (Bool).
///
/// The mascot is never static — it always has some animation running.
/// - idle: Rive's built-in idle loop (blinking, breathing)
/// - typing: cycles happy ↔ idle on each keystroke burst
/// - waiting: sad face, with periodic nervous glances (sad ↔ idle flicker)
/// - responding: happy, with gentle idle dips so it doesn't freeze
///
/// Pausing while typing triggers a graceful fallback to idle after a delay.
@MainActor
final class MascotView {
    private(set) var currentState: MascotState = .idle
    private let riveViewModel: RiveViewModel
    private let mascotSize: CGFloat = 40

    /// Timer for cycling animations within a state.
    private var cycleTimer: Timer?
    private var cycleToggle = false

    /// Timer that fires when the user stops typing, to fall back to idle.
    private var typingIdleTimer: Timer?

    /// Timer for gentle idle "breathing" — periodic micro-expressions.
    private var idleBreathTimer: Timer?

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
        applyState(state)
    }

    /// Stops running timers and applies the animation for the given state.
    /// Called by both `setState` (on transitions) and `resume` (re-applying the current state).
    private func applyState(_ state: MascotState) {
        stopAllTimers()

        switch state {
        case .idle:
            applyIdle()
            startIdleBreathing()
        case .typing:
            startTypingCycle()
        case .waiting:
            startWaitingCycle()
        case .responding:
            startRespondingCycle()
        }
    }

    /// Called on every keystroke — resets the "stopped typing" timer.
    func notifyKeystroke() {
        typingIdleTimer?.invalidate()

        // If not in typing state, switch to it
        if currentState != .typing {
            setState(.typing)
        }

        // Reset the pause timer — if no keystroke for 1.2s, ease back to idle
        typingIdleTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .typing else { return }
                self.setState(.idle)
            }
        }
    }

    // MARK: - Idle

    private func applyIdle() {
        riveViewModel.setInput("isHappy", value: false)
        riveViewModel.setInput("isSad", value: false)
    }

    /// Idle isn't truly static — periodically flash a micro-smile to feel alive.
    private func startIdleBreathing() {
        idleBreathTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .idle else {
                    self?.idleBreathTimer?.invalidate()
                    self?.idleBreathTimer = nil
                    return
                }
                // Brief happy flash
                self.riveViewModel.setInput("isHappy", value: true)
                self.scheduleRevert(delay: .seconds(0.6), expectedState: .idle) {
                    $0.riveViewModel.setInput("isHappy", value: false)
                }
            }
        }
    }

    // MARK: - Typing

    private func startTypingCycle() {
        cycleToggle = true
        applyTypingToggle()

        cycleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .typing else {
                    self?.cycleTimer?.invalidate()
                    self?.cycleTimer = nil
                    return
                }
                self.cycleToggle.toggle()
                self.applyTypingToggle()
            }
        }
    }

    private func applyTypingToggle() {
        riveViewModel.setInput("isSad", value: false)
        riveViewModel.setInput("isHappy", value: cycleToggle)
    }

    // MARK: - Waiting

    /// Waiting: mostly sad, but flickers to idle briefly to look nervous/alive.
    private func startWaitingCycle() {
        riveViewModel.setInput("isHappy", value: false)
        riveViewModel.setInput("isSad", value: true)

        cycleTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .waiting else {
                    self?.cycleTimer?.invalidate()
                    self?.cycleTimer = nil
                    return
                }
                // Brief nervous glance — drop sad, then restore
                self.riveViewModel.setInput("isSad", value: false)
                self.scheduleRevert(delay: .seconds(0.4), expectedState: .waiting) {
                    $0.riveViewModel.setInput("isSad", value: true)
                }
            }
        }
    }

    // MARK: - Responding

    /// Responding: mostly happy, with gentle idle dips so it doesn't freeze.
    private func startRespondingCycle() {
        riveViewModel.setInput("isSad", value: false)
        riveViewModel.setInput("isHappy", value: true)

        cycleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .responding else {
                    self?.cycleTimer?.invalidate()
                    self?.cycleTimer = nil
                    return
                }
                // Brief neutral dip
                self.riveViewModel.setInput("isHappy", value: false)
                self.scheduleRevert(delay: .seconds(0.5), expectedState: .responding) {
                    $0.riveViewModel.setInput("isHappy", value: true)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Schedules a delayed revert action, only executing if the mascot is still
    /// in the expected state when the delay elapses.
    private func scheduleRevert(
        delay: Duration,
        expectedState: MascotState,
        action: @escaping (MascotView) -> Void
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, currentState == expectedState else { return }
            action(self)
        }
    }

    // MARK: - Pause / Resume

    /// Stops the Rive state machine and all timers to save GPU/CPU while the panel is hidden.
    func pause() {
        riveViewModel.pause()
        stopAllTimers()
        mascotLogger.info("Mascot paused")
    }

    /// Restarts the Rive state machine and re-applies the current animation state.
    func resume() {
        riveViewModel.play()
        applyState(currentState)
        mascotLogger.info("Mascot resumed")
    }

    // MARK: - Cleanup

    private func stopAllTimers() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        typingIdleTimer?.invalidate()
        typingIdleTimer = nil
        idleBreathTimer?.invalidate()
        idleBreathTimer = nil
        cycleToggle = false
    }
}
