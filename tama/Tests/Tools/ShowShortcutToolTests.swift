import AppKit
import Foundation
@testable import Tama
import Testing

@Suite("ShowShortcutTool")
struct ShowShortcutToolTests {
    private func tool() -> ShowShortcutTool { ShowShortcutTool() }

    @Test("name is 'show_shortcut'")
    func toolName() {
        #expect(tool().name == "show_shortcut")
    }

    @Test("description explains HUD purpose with examples")
    func descriptionContent() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("shortcut"))
        #expect(desc.contains("hud") || desc.contains("keycap"))
        #expect(desc.contains("cmd") || desc.contains("⌘"))
    }

    @Test("input schema requires shortcut")
    func inputSchemaRequired() {
        let schema = tool().inputSchema
        let required = schema["required"] as? [String] ?? []
        #expect(required == ["shortcut"])
    }

    @Test("missing shortcut throws missingArgument")
    func missingShortcut() async {
        do {
            _ = try await tool().execute(args: [:])
            Issue.record("Expected missingArgument error")
        } catch let error as ShowShortcutToolError {
            if case .missingArgument = error { /* ok */ } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    // MARK: - Parser

    @Test("parses cmd+s into ⌘ S keycaps")
    func parseCmdS() {
        let keys = ShowShortcutTool.parse(shortcut: "cmd+s")
        #expect(keys.count == 2)
        #expect(keys[0].glyph == "⌘")
        #expect(keys[0].isModifier == true)
        #expect(keys[1].glyph == "S")
        #expect(keys[1].isModifier == false)
    }

    @Test("parses cmd+shift+4 into ⌘ ⇧ 4")
    func parseCmdShift4() {
        let keys = ShowShortcutTool.parse(shortcut: "cmd+shift+4")
        #expect(keys.count == 3)
        #expect(keys.map(\.glyph) == ["⌘", "⇧", "4"])
    }

    @Test("parses special keys like enter and esc")
    func parseSpecials() {
        #expect(ShowShortcutTool.parse(shortcut: "enter").first?.glyph == "↵")
        #expect(ShowShortcutTool.parse(shortcut: "escape").first?.glyph == "⎋")
        #expect(ShowShortcutTool.parse(shortcut: "tab").first?.glyph == "⇥")
        #expect(ShowShortcutTool.parse(shortcut: "space").first?.glyph == "␣")
    }

    @Test("parses arrow keys")
    func parseArrows() {
        #expect(ShowShortcutTool.parse(shortcut: "up").first?.glyph == "↑")
        #expect(ShowShortcutTool.parse(shortcut: "down").first?.glyph == "↓")
        #expect(ShowShortcutTool.parse(shortcut: "left").first?.glyph == "←")
        #expect(ShowShortcutTool.parse(shortcut: "right").first?.glyph == "→")
    }

    @Test("parses function keys")
    func parseFunctionKeys() {
        #expect(ShowShortcutTool.parse(shortcut: "f5").first?.glyph == "F5")
        #expect(ShowShortcutTool.parse(shortcut: "f12").first?.glyph == "F12")
    }

    @Test("parses Unicode aliases without keywords")
    func parseUnicodeAliases() {
        let keys = ShowShortcutTool.parse(shortcut: "⌘+⇧+p")
        #expect(keys.map(\.glyph) == ["⌘", "⇧", "P"])
    }

    @Test("valid shortcut executes without errors")
    @MainActor
    func happyPath() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        let result = try await tool().execute(args: [
            "shortcut": "cmd+s",
            "label": "Save",
            "hold_seconds": 0.5,
        ])
        #expect(result.text.contains("⌘"))
        #expect(result.text.contains("S"))
        VirtualCursorController.hideImmediately()
    }
}
