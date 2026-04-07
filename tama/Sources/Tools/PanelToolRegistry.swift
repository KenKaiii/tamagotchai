import Foundation

/// Registry of available panel tools.
@MainActor
final class PanelToolRegistry {
    static let shared = PanelToolRegistry()

    private(set) var allTools: [PanelTool] = []

    private init() {
        register(ClipboardHistoryTool())
        register(KeepAwakeTool())
        if NightShiftTool.isSupported {
            register(NightShiftTool())
        }
    }

    func register(_ tool: PanelTool) {
        allTools.append(tool)
    }

    func search(query: String) -> [PanelTool] {
        guard !query.isEmpty else { return allTools }
        let lowered = query.lowercased()
        return allTools.filter {
            $0.name.lowercased().contains(lowered)
                || $0.toolDescription.lowercased().contains(lowered)
        }
    }
}
