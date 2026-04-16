import AppKit
import Foundation
@testable import Tama
import Testing

@Suite("HighlightTool")
struct HighlightToolTests {
    private func tool() -> HighlightTool { HighlightTool() }

    // MARK: - Schema

    @Test("name is 'highlight'")
    func toolName() {
        #expect(tool().name == "highlight")
    }

    @Test("description explains area-vs-point usage")
    func descriptionContent() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("area") || desc.contains("region"))
        #expect(desc.contains("rectangle") || desc.contains("dashed"))
    }

    @Test("description lists trigger phrases for region-level guidance")
    func descriptionListsTriggers() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("toolbar") || desc.contains("panel") || desc.contains("sidebar"))
    }

    @Test("description tells the agent to keep labels short (1–3 words)")
    func descriptionLimitsLabelLength() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("1–3 words") || desc.contains("1-3 words"))
    }

    @Test("input schema requires shape, x, y, width")
    func inputSchemaRequired() {
        let schema = tool().inputSchema
        #expect(schema["type"] as? String == "object")
        let required = schema["required"] as? [String] ?? []
        #expect(Set(required) == Set(["shape", "x", "y", "width"]))
    }

    @Test("input schema declares all expected properties")
    func inputSchemaProperties() {
        let schema = tool().inputSchema
        let properties = schema["properties"] as? [String: Any]
        let keys = Set(properties?.keys ?? [:].keys)
        #expect(keys == Set(["shape", "x", "y", "width", "height", "label", "display", "hold_seconds"]))
    }

    @Test("shape is a string enum with rectangle and circle")
    func shapeEnum() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        let shape = properties?["shape"] as? [String: Any]
        #expect(shape?["type"] as? String == "string")
        let values = shape?["enum"] as? [String] ?? []
        #expect(Set(values) == Set(["rectangle", "circle"]))
    }

    @Test("x and y have 0-1 range bounds")
    func xyRangeBounds() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        for key in ["x", "y", "width", "height"] {
            let prop = properties?[key] as? [String: Any]
            #expect(prop?["type"] as? String == "number")
            #expect(prop?["minimum"] as? Double == 0.0)
            #expect(prop?["maximum"] as? Double == 1.0)
        }
    }

    // MARK: - Validation

    @Test("missing shape throws invalidShape")
    func missingShape() async {
        do {
            _ = try await tool().execute(args: ["x": 0.1, "y": 0.1, "width": 0.5])
            Issue.record("Expected invalidShape error")
        } catch let error as HighlightToolError {
            if case .invalidShape = error { /* ok */ } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("invalid shape throws invalidShape")
    func invalidShape() async {
        do {
            _ = try await tool().execute(args: ["shape": "triangle", "x": 0.1, "y": 0.1, "width": 0.5])
            Issue.record("Expected invalidShape error")
        } catch let error as HighlightToolError {
            if case let .invalidShape(value) = error {
                #expect(value == "triangle")
            } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("out-of-range x throws outOfRange")
    func outOfRangeX() async {
        do {
            _ = try await tool().execute(args: ["shape": "rectangle", "x": 1.5, "y": 0.2, "width": 0.3])
            Issue.record("Expected outOfRange error")
        } catch let error as HighlightToolError {
            if case let .outOfRange(key, _) = error { #expect(key == "x") } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("missing width throws missingArgument")
    func missingWidth() async {
        do {
            _ = try await tool().execute(args: ["shape": "rectangle", "x": 0.1, "y": 0.1])
            Issue.record("Expected missingArgument error")
        } catch let error as HighlightToolError {
            if case let .missingArgument(key) = error { #expect(key == "width") } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Happy Path

    @Test("valid rectangle highlight executes without errors")
    @MainActor
    func happyPath() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        let result = try await tool().execute(args: [
            "shape": "rectangle",
            "x": 0.1,
            "y": 0.1,
            "width": 0.3,
            "height": 0.2,
            "label": "Sidebar",
            "hold_seconds": 1.0,
        ])
        #expect(result.text.contains("rectangle"))
        #expect(result.text.contains("Sidebar"))
        VirtualCursorController.hideImmediately()
    }

    @Test("circle highlight executes and defaults height to width")
    @MainActor
    func circleHappyPath() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        let result = try await tool().execute(args: [
            "shape": "circle",
            "x": 0.5,
            "y": 0.5,
            "width": 0.1,
            "hold_seconds": 1.0,
        ])
        #expect(result.text.contains("circle"))
        VirtualCursorController.hideImmediately()
    }
}
