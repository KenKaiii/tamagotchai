import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "menubar.mood"
)

/// Observable singleton that tracks the current mood for the menu bar icon.
/// Activity moods (listening, thinking, etc.) override time-of-day moods.
/// When no activity is happening, a 60-second timer keeps the time-of-day mood current.
@Observable
@MainActor
final class MenuBarMood {
    static let shared = MenuBarMood()

    /// The current mood displayed in the menu bar icon.
    private(set) var mood: Mood = .afternoon

    /// Animation frame toggle for thinking state (antenna wobble).
    private(set) var animationFrame: Bool = false

    private var activity: Mood?
    private var timer: Timer?
    private var animationTimer: Timer?

    private init() {
        mood = Self.timeOfDayMood()
        startTimer()
    }

    // MARK: - Mood Enum

    enum Mood: String, CaseIterable {
        // Time-of-day (passive)
        case morning // 6am–12pm
        case afternoon // 12pm–5pm
        case evening // 5pm–9pm
        case night // 9pm–12am
        case lateNight // 12am–6am

        // Activity (override)
        case listening
        case thinking
        case responding
        case speaking
        case error

        var isActivity: Bool {
            switch self {
            case .listening, .thinking, .responding, .speaking, .error:
                true
            default:
                false
            }
        }
    }

    // MARK: - Activity Control

    /// Set an activity mood (overrides time-of-day). Pass `nil` to clear.
    func setActivity(_ activity: Mood?) {
        if let activity {
            logger.debug("Menu bar activity: \(activity.rawValue)")
        } else {
            logger.debug("Menu bar activity cleared")
        }
        self.activity = activity

        if let activity, activity.isActivity {
            startAnimationTimer()
        } else {
            stopAnimationTimer()
        }

        recalculate()
    }

    // MARK: - Time of Day

    private static func timeOfDayMood() -> Mood {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6 ..< 12:
            return .morning
        case 12 ..< 17:
            return .afternoon
        case 17 ..< 21:
            return .evening
        case 21 ..< 24:
            return .night
        default:
            return .lateNight
        }
    }

    private func recalculate() {
        mood = activity ?? Self.timeOfDayMood()
    }

    // MARK: - Timers

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recalculate()
            }
        }
    }

    private func startAnimationTimer() {
        stopAnimationTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.animationFrame.toggle()
            }
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = false
    }
}
