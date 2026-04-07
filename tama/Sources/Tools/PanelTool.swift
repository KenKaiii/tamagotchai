import AppKit

/// Protocol for tools that appear in the panel's Tools tab.
/// Separate from `AgentTool` (which is for AI tool calling) — these are
/// user-facing utilities invoked directly from the Tools command list.
@MainActor
protocol PanelTool: AnyObject {
    /// Unique identifier for the tool.
    var id: String { get }

    /// Display name shown in the tool list.
    var name: String { get }

    /// SF Symbol name for the tool icon.
    var icon: String { get }

    /// Short description shown below the tool name.
    var toolDescription: String { get }

    /// Optional keyboard shortcut hint displayed on the trailing edge (e.g. "⌘⇧V").
    var shortcutHint: String? { get }

    /// Placeholder text for the input field when this tool is active.
    var searchPlaceholder: String { get }

    /// Creates the tool's content view for display in the panel.
    func makeView() -> NSView

    /// Called when the input field text changes while this tool is active.
    func filterContent(query: String)
}
