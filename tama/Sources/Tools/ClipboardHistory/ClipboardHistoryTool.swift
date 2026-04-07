import AppKit

/// Panel tool that provides searchable clipboard history.
@MainActor
final class ClipboardHistoryTool: PanelTool {
    let id = "clipboard-history"
    let name = "Clipboard History"
    let icon = "doc.on.clipboard"
    let toolDescription = "Browse and search your clipboard history"
    let shortcutHint: String? = nil
    let searchPlaceholder = "Search clipboard..."

    private var historyView: ClipboardHistoryView?

    func makeView() -> NSView {
        let view = ClipboardHistoryView()
        historyView = view
        return view
    }

    func filterContent(query: String) {
        historyView?.filter(query: query)
    }
}
