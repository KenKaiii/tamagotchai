import AppKit

/// A panel tool that acts as an on/off toggle rather than drilling into a subview.
/// Toggle tools are displayed inline in the tool list with a switch control.
@MainActor
protocol TogglePanelTool: PanelTool {
    /// Whether the toggle is currently enabled.
    var isEnabled: Bool { get }

    /// Flip the toggle state. Implementations should update `isEnabled` accordingly.
    func toggle()

    /// Optional: called when the toggle state changes so the tool row can update.
    var onStateChanged: (() -> Void)? { get set }
}

// MARK: - Defaults for TogglePanelTool

extension TogglePanelTool {
    var searchPlaceholder: String { "" }

    func makeView() -> NSView { NSView() }

    func filterContent(query _: String) {}
}
