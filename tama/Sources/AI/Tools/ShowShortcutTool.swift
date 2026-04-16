import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.show_shortcut"
)

/// Agent tool that displays a centred keycap HUD for a keyboard shortcut.
/// Much clearer than typing "Cmd+Shift+S" in a reply when you're teaching a
/// shortcut — the user sees the exact glyphs they'll find on their keyboard.
struct ShowShortcutTool: AgentTool, @unchecked Sendable {
    let name = "show_shortcut"
    let description = """
    Display a centred keyboard-shortcut HUD with keycap glyphs (⌘ ⇧ ⌥ ⌃ + letters). Use when \
    teaching a shortcut — it's much clearer than typing "Cmd+Shift+S" in a reply.

    ## Format

    Pass `shortcut` as a plus-separated string:
    - "cmd+s" → ⌘ S
    - "cmd+shift+4" → ⌘ ⇧ 4
    - "cmd+," → ⌘ ,
    - "enter" → ↵
    - "cmd+shift+p" → ⌘ ⇧ P

    Recognized modifiers: cmd/command, shift, opt/option/alt, ctrl/control.
    Recognized special keys: enter/return, esc/escape, space, tab, delete, up/down/left/right, f1-f12.

    ## Use cases
    - "How do I save? → `show_shortcut` with "cmd+s", then say "Cmd-S saves it."
    - "Try the Quick Open shortcut → `show_shortcut` with "cmd+shift+p"
    - Any time you mention a shortcut in your reply, consider showing it visually.

    ## Label
    Optional one-line description under the keycaps ("Save", "Quick Open"). Keep it short.
    """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "shortcut": [
                    "type": "string",
                    "description": "Plus-separated shortcut — e.g. \"cmd+s\", \"cmd+shift+4\", \"enter\".",
                ],
                "label": [
                    "type": "string",
                    "description": "Optional short caption under the keycaps (e.g. \"Save\", \"Find\").",
                ],
                "display": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "0-based display index (default: 0 = main).",
                ],
                "hold_seconds": [
                    "type": "number",
                    "minimum": 0.5,
                    "maximum": 30.0,
                    "description": "How long the HUD stays visible, in seconds. Default 2.5.",
                ],
            ],
            "required": ["shortcut"],
        ]
    }

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let shortcut = args["shortcut"] as? String,
              !shortcut.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw ShowShortcutToolError.missingArgument(key: "shortcut")
        }
        let keys = Self.parse(shortcut: shortcut)
        guard !keys.isEmpty else {
            throw ShowShortcutToolError.invalidShortcut(shortcut)
        }

        let label = args["label"] as? String
        let displayIndex = (args["display"] as? Int) ?? 0
        let explicitHold = (args["hold_seconds"] as? Double)
            ?? (args["hold_seconds"] as? Int).map(Double.init)
        let holdSeconds = explicitHold ?? 2.5

        try await MainActor.run { () throws in
            let available = VirtualCursorController.screenCount
            guard available > 0 else { throw ShowShortcutToolError.noDisplays }
            guard let screen = VirtualCursorController.screen(forIndex: displayIndex) else {
                throw ShowShortcutToolError.invalidDisplay(index: displayIndex, available: available)
            }
            VirtualCursorController.showShortcut(
                keys: keys,
                label: label,
                on: screen,
                holdSeconds: holdSeconds
            )
        }

        let rendered = keys.map(\.glyph).joined(separator: " ")
        logger.info("Show shortcut HUD '\(rendered, privacy: .public)' on display \(displayIndex)")
        return ToolOutput(text: "Shortcut HUD shown: \(rendered) on display \(displayIndex)")
    }

    // MARK: - Shortcut parser

    /// Parse a plus-separated shortcut string like "cmd+shift+s" into an
    /// ordered list of `ShortcutKey` values. Modifiers are mapped to their
    /// Unicode keycap glyphs; special keys have their own glyph mappings;
    /// unknown single-character tokens fall back to uppercase letters.
    static func parse(shortcut: String) -> [VirtualCursorPanel.ShortcutKey] {
        let tokens = shortcut
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        var keys: [VirtualCursorPanel.ShortcutKey] = []
        for token in tokens {
            if let modifier = modifierGlyph(for: token) {
                keys.append(.init(glyph: modifier, isModifier: true))
                continue
            }
            if let special = specialGlyph(for: token) {
                keys.append(.init(glyph: special, isModifier: false))
                continue
            }
            // Single-character tokens render as uppercase letters. Longer
            // unknown tokens render as-is (uppercased) so the user still sees
            // what they typed.
            let fallback = token.count == 1 ? token.uppercased() : token.capitalized
            keys.append(.init(glyph: fallback, isModifier: false))
        }
        return keys
    }

    private static func modifierGlyph(for token: String) -> String? {
        switch token {
        case "cmd", "command", "⌘": "⌘"
        case "shift", "⇧": "⇧"
        case "opt", "option", "alt", "⌥": "⌥"
        case "ctrl", "control", "⌃": "⌃"
        case "fn", "function": "fn"
        default: nil
        }
    }

    private static func specialGlyph(for token: String) -> String? {
        switch token {
        case "enter", "return", "↵": return "↵"
        case "esc", "escape", "⎋": return "⎋"
        case "space", "␣": return "␣"
        case "tab", "⇥": return "⇥"
        case "delete", "backspace", "⌫": return "⌫"
        case "forward-delete", "forwarddelete", "⌦": return "⌦"
        case "up", "↑": return "↑"
        case "down", "↓": return "↓"
        case "left", "←": return "←"
        case "right", "→": return "→"
        case "pageup", "pgup": return "⇞"
        case "pagedown", "pgdn": return "⇟"
        case "home": return "↖"
        case "end": return "↘"
        default:
            // Function keys f1-f12 — pass through capitalised.
            if token.count >= 2, token.first == "f",
               let number = Int(token.dropFirst()), (1 ... 24).contains(number)
            {
                return "F\(number)"
            }
            return nil
        }
    }
}

// MARK: - Errors

enum ShowShortcutToolError: LocalizedError, Equatable {
    case missingArgument(key: String)
    case invalidShortcut(String)
    case invalidDisplay(index: Int, available: Int)
    case noDisplays

    var errorDescription: String? {
        switch self {
        case let .missingArgument(key):
            "Missing required parameter: \(key)"
        case let .invalidShortcut(value):
            "Couldn't parse shortcut '\(value)'. Use plus-separated tokens like \"cmd+shift+s\"."
        case let .invalidDisplay(index, available):
            "Display index \(index) is out of range. Available displays: 0…\(max(0, available - 1))."
        case .noDisplays:
            "No displays are currently attached."
        }
    }
}
