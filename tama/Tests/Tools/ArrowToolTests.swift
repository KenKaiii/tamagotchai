import AppKit
import Foundation
@testable import Tama
import Testing

@Suite("ArrowTool")
struct ArrowToolTests {
    private func tool() -> ArrowTool { ArrowTool() }

    @Test("name is 'arrow'")
    func toolName() {
        #expect(tool().name == "arrow")
    }

    @Test("description explains directional guidance")
    func descriptionContent() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("arrow"))
        #expect(desc.contains("drag") || desc.contains("direction") || desc.contains("flow"))
    }

    @Test("description lists trigger phrases")
    func descriptionListsTriggers() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("drag"))
    }

    @Test("input schema requires x1, y1, x2, y2")
    func inputSchemaRequired() {
        let schema = tool().inputSchema
        let required = schema["required"] as? [String] ?? []
        #expect(Set(required) == Set(["x1", "y1", "x2", "y2"]))
    }

    @Test("style enum includes solid and dashed")
    func styleEnum() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        let style = properties?["style"] as? [String: Any]
        let values = style?["enum"] as? [String] ?? []
        #expect(Set(values) == Set(["solid", "dashed"]))
    }

    @Test("coords have 0-1 range bounds")
    func coordsBounds() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        for key in ["x1", "y1", "x2", "y2"] {
            let prop = properties?[key] as? [String: Any]
            #expect(prop?["type"] as? String == "number")
            #expect(prop?["minimum"] as? Double == 0.0)
            #expect(prop?["maximum"] as? Double == 1.0)
        }
    }

    @Test("missing x1 throws missingArgument")
    func missingX1() async {
        do {
            _ = try await tool().execute(args: ["y1": 0.1, "x2": 0.5, "y2": 0.5])
            Issue.record("Expected missingArgument error")
        } catch let error as ArrowToolError {
            if case let .missingArgument(key) = error { #expect(key == "x1") } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    @Test("out-of-range y2 throws outOfRange")
    func outOfRange() async {
        do {
            _ = try await tool().execute(args: ["x1": 0.1, "y1": 0.1, "x2": 0.5, "y2": 2.0])
            Issue.record("Expected outOfRange error")
        } catch let error as ArrowToolError {
            if case let .outOfRange(key, _) = error { #expect(key == "y2") } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    @Test("too-short arrow throws tooShort")
    func tooShort() async {
        do {
            _ = try await tool().execute(args: ["x1": 0.5, "y1": 0.5, "x2": 0.505, "y2": 0.505])
            Issue.record("Expected tooShort error")
        } catch let error as ArrowToolError {
            if case .tooShort = error { /* ok */ } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    @Test("valid arrow executes without errors")
    @MainActor
    func happyPath() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        let result = try await tool().execute(args: [
            "x1": 0.2,
            "y1": 0.2,
            "x2": 0.7,
            "y2": 0.6,
            "label": "Drag here",
            "hold_seconds": 1.0,
        ])
        #expect(result.text.contains("0.2"))
        #expect(result.text.contains("0.7"))
        #expect(result.text.contains("Drag here"))
        VirtualCursorController.hideImmediately()
    }
}
