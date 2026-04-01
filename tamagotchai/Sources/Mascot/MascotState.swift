import Foundation

/// The different animation states for the mascot.
/// Each state maps to a state or animation name in the Rive file.
enum MascotState: String, CaseIterable {
    /// Default — mascot is idle, gently breathing/blinking.
    case idle
    /// User is typing in the prompt field.
    case typing
    /// Prompt submitted, waiting for AI response.
    case waiting
    /// AI response is streaming in.
    case responding
}
