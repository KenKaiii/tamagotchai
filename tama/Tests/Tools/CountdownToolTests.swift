import AppKit
import Foundation
@testable import Tama
import Testing

@Suite("CountdownTool")
struct CountdownToolTests {
    private func tool() -> CountdownTool { CountdownTool() }

    @Test("name is 'countdown'")
    func toolName() {
        #expect(tool().name == "countdown")
    }

    @Test("description says it does NOT click for the user")
    func descriptionClarifiesNoClick() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("not click") || desc.contains("does not"))
    }

    @Test("description mentions pacing / narration pairing")
    func descriptionMentionsPairing() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("narrate") || desc.contains("narration") || desc.contains("pace"))
    }

    @Test("input schema requires seconds only")
    func inputSchemaRequired() {
        let schema = tool().inputSchema
        let required = schema["required"] as? [String] ?? []
        #expect(required == ["seconds"])
    }

    @Test("seconds has 1-30 range bounds")
    func secondsBounds() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        let seconds = properties?["seconds"] as? [String: Any]
        #expect(seconds?["type"] as? String == "number")
        #expect(seconds?["minimum"] as? Double == 1.0)
        #expect(seconds?["maximum"] as? Double == 30.0)
    }

    @Test("out-of-range seconds throws outOfRange")
    func outOfRangeSeconds() async {
        do {
            _ = try await tool().execute(args: ["seconds": 60])
            Issue.record("Expected outOfRange error")
        } catch let error as CountdownToolError {
            if case let .outOfRange(key, _) = error { #expect(key == "seconds") } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    @Test("missing seconds throws missingArgument")
    func missingSeconds() async {
        do {
            _ = try await tool().execute(args: [:])
            Issue.record("Expected missingArgument error")
        } catch let error as CountdownToolError {
            if case let .missingArgument(key) = error { #expect(key == "seconds") } else {
                Issue.record("Wrong case: \(error)")
            }
        } catch {
            Issue.record("Unexpected type: \(error)")
        }
    }

    @Test("valid countdown executes without errors")
    @MainActor
    func happyPath() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        let result = try await tool().execute(args: [
            "seconds": 2,
            "label": "Get ready",
        ])
        #expect(result.text.contains("2s") || result.text.contains("Countdown"))
        VirtualCursorController.hideImmediately()
    }
}
