import AppKit
import Foundation
@testable import Tama
import Testing

@Suite("ScrollHintTool")
struct ScrollHintToolTests {
    private func tool() -> ScrollHintTool { ScrollHintTool() }

    @Test("name is 'scroll_hint'")
    func toolName() {
        #expect(tool().name == "scroll_hint")
    }

    @Test("description lists trigger phrases")
    func descriptionListsTriggers() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("scroll"))
        #expect(desc.contains("offscreen") || desc.contains("keep scrolling"))
    }

    @Test("direction enum includes up/down/left/right")
    func directionEnum() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        let direction = properties?["direction"] as? [String: Any]
        let values = direction?["enum"] as? [String] ?? []
        #expect(Set(values) == Set(["up", "down", "left", "right"]))
    }

    @Test("input schema requires direction")
    func inputSchemaRequired() {
        let schema = tool().inputSchema
        let required = schema["required"] as? [String] ?? []
        #expect(required == ["direction"])
    }

    @Test("invalid direction throws invalidDirection")
    func invalidDirection() async {
        do {
            _ = try await tool().execute(args: ["direction": "diagonal"])
            Issue.record("Expected invalidDirection error")
        } catch let error as ScrollHintToolError {
            if case .invalidDirection = error { /* ok */ } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    @Test("valid scroll hint executes without errors")
    @MainActor
    func happyPath() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        let result = try await tool().execute(args: [
            "direction": "down",
            "label": "Keep scrolling",
            "hold_seconds": 1.0,
        ])
        #expect(result.text.contains("down"))
        #expect(result.text.contains("Keep scrolling"))
        VirtualCursorController.hideImmediately()
    }
}
