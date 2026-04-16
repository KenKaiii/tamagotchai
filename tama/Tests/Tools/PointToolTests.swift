import AppKit
import Foundation
@testable import Tama
import Testing

@Suite("PointTool")
struct PointToolTests {
    private func tool() -> PointTool { PointTool() }

    // MARK: - Schema

    @Test("name is 'point'")
    func toolName() {
        #expect(tool().name == "point")
    }

    @Test("description explains tutor mode and normalized coords")
    func descriptionContent() {
        let desc = tool().description.lowercased()
        #expect(desc.contains("virtual cursor"))
        #expect(desc.contains("real cursor"))
        // Mentions the coordinate system explicitly.
        #expect(desc.contains("0") && desc.contains("1"))
    }

    @Test("description lists trigger phrases so the model knows when to call it")
    func descriptionListsTriggers() {
        // The description is the primary signal the model uses to decide to call
        // a tool — make sure the natural user phrasings that should activate
        // point are explicitly listed. If these regress, the agent will stop
        // invoking the tool proactively.
        let desc = tool().description.lowercased()
        #expect(desc.contains("where"), "Description must list 'where's...' as a trigger")
        #expect(desc.contains("how do i"), "Description must list 'how do I...' as a trigger")
        #expect(
            desc.contains("show me") || desc.contains("walk me through"),
            "Description must list show/walk triggers"
        )
        #expect(desc.contains("proactively"), "Description must tell the model to call it proactively")
    }

    @Test("description pairs point with screenshot as a workflow")
    func descriptionMentionsScreenshotPairing() {
        // The see-point-explain pattern only works if the model knows to take
        // a screenshot first. The tool description must explicitly link them.
        let desc = tool().description.lowercased()
        #expect(desc.contains("screenshot"), "Description must reference the screenshot tool")
    }

    @Test("description tells the agent to keep labels short (1–3 words)")
    func descriptionLimitsLabelLength() {
        // The pill next to the cursor grows to fit the label and never
        // truncates, so long labels create huge pills that cover what
        // they're pointing at. The tool description must instruct the
        // agent to keep it to a few words.
        let desc = tool().description.lowercased()
        #expect(
            desc.contains("1–3 words") || desc.contains("1-3 words"),
            "Description must cap label length at 1–3 words"
        )
        // Label schema description must also carry the guidance — this is
        // what the model sees for the `label` field specifically.
        let properties = tool().inputSchema["properties"] as? [String: Any]
        let labelProp = properties?["label"] as? [String: Any]
        let labelDesc = (labelProp?["description"] as? String)?.lowercased() ?? ""
        #expect(
            labelDesc.contains("1–3 words") || labelDesc.contains("1-3 words"),
            "Label schema must tell the model to keep it to 1–3 words"
        )
    }

    @Test("description teaches precision strategies for small targets")
    func descriptionTeachesPrecision() {
        // When the target is a menu-bar icon or toolbar button (<5% of screen),
        // the agent needs to anchor to landmarks and know about macOS quirks
        // (wifi/bluetooth live inside Control Center). Without this, the agent
        // confidently lands on the wrong icon — exactly the bug the user hit.
        let desc = tool().description.lowercased()
        #expect(
            desc.contains("landmark") || desc.contains("anchor"),
            "Description must teach landmark-based positioning for small targets"
        )
        #expect(
            desc.contains("control center"),
            "Description must warn about wifi/bluetooth living inside Control Center"
        )
    }

    @Test("description tells the agent to re-point after user correction")
    func descriptionTeachesCorrectionLoop() {
        // If the user says the cursor is off, the agent should take a fresh
        // screenshot (virtual cursor shows in subsequent shots) and re-point —
        // not just guess an adjustment. This closes the feedback loop.
        let desc = tool().description.lowercased()
        #expect(
            desc.contains("fresh") || desc.contains("new screenshot") || desc.contains("re-point"),
            "Description must instruct the agent to re-screenshot and re-point on user correction"
        )
    }

    @Test("description teaches multi-step walkthrough pacing")
    func descriptionTeachesMultiStepPacing() {
        // For "walk me through X" requests the agent should point at step 1,
        // WAIT for user ack, take a fresh screenshot, then point at step 2 —
        // not fire everything at once. Without explicit prompt guidance the
        // agent tends to collapse all steps into one turn and the cursor
        // races past the user.
        let desc = tool().description.lowercased()
        #expect(
            desc.contains("walk") || desc.contains("walkthrough") || desc.contains("multi-step"),
            "Description must mention multi-step / walkthrough pattern"
        )
        #expect(
            desc.contains("ack") || desc.contains("wait for") || desc.contains("confirmation"),
            "Description must tell the agent to wait for user acknowledgement between steps"
        )
        #expect(
            desc.contains("one cursor") || desc.contains("one point per") || desc.contains("one at a time"),
            "Description must tell the agent to issue one point per turn during walkthroughs"
        )
    }

    @Test("input schema requires x and y")
    func inputSchemaRequired() {
        let schema = tool().inputSchema
        #expect(schema["type"] as? String == "object")

        let required = schema["required"] as? [String] ?? []
        #expect(Set(required) == Set(["x", "y"]))
    }

    @Test("input schema declares all expected properties")
    func inputSchemaProperties() {
        let schema = tool().inputSchema
        let properties = schema["properties"] as? [String: Any]
        #expect(properties != nil)
        let keys = Set(properties?.keys ?? [:].keys)
        #expect(keys == Set(["x", "y", "display", "label", "pulse", "hold_seconds", "upcoming"]))
    }

    @Test("x and y have 0-1 range bounds")
    func xyRangeBounds() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        for key in ["x", "y"] {
            let prop = properties?[key] as? [String: Any]
            #expect(prop?["type"] as? String == "number")
            #expect(prop?["minimum"] as? Double == 0.0)
            #expect(prop?["maximum"] as? Double == 1.0)
        }
    }

    @Test("display is a non-negative integer")
    func displayType() {
        let properties = tool().inputSchema["properties"] as? [String: Any]
        let display = properties?["display"] as? [String: Any]
        #expect(display?["type"] as? String == "integer")
        #expect(display?["minimum"] as? Int == 0)
    }

    // MARK: - Argument Validation

    @Test("missing x throws missingArgument")
    func missingX() async {
        do {
            _ = try await tool().execute(args: ["y": 0.5])
            Issue.record("Expected missingArgument error")
        } catch let error as PointToolError {
            #expect(error == .missingArgument(key: "x"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("missing y throws missingArgument")
    func missingY() async {
        do {
            _ = try await tool().execute(args: ["x": 0.5])
            Issue.record("Expected missingArgument error")
        } catch let error as PointToolError {
            #expect(error == .missingArgument(key: "y"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("out-of-range x throws outOfRange")
    func outOfRangeX() async {
        do {
            _ = try await tool().execute(args: ["x": 1.5, "y": 0.5])
            Issue.record("Expected outOfRange error")
        } catch let error as PointToolError {
            if case let .outOfRange(key, value) = error {
                #expect(key == "x")
                #expect(value == 1.5)
            } else {
                Issue.record("Wrong PointToolError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("negative y throws outOfRange")
    func negativeY() async {
        do {
            _ = try await tool().execute(args: ["x": 0.5, "y": -0.1])
            Issue.record("Expected outOfRange error")
        } catch let error as PointToolError {
            if case let .outOfRange(key, _) = error {
                #expect(key == "y")
            } else {
                Issue.record("Wrong PointToolError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("invalid display index throws invalidDisplay with available count")
    func invalidDisplay() async {
        // There's always at least one display under test (the virtual host
        // display). Use a deliberately huge index so the tool must reject it.
        do {
            _ = try await tool().execute(args: ["x": 0.5, "y": 0.5, "display": 9999])
            Issue.record("Expected invalidDisplay error")
        } catch let error as PointToolError {
            if case let .invalidDisplay(index, _) = error {
                #expect(index == 9999)
            } else {
                Issue.record("Wrong PointToolError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Happy Path

    @Test("valid coords on main display succeed and mention the point in the result text")
    @MainActor
    func happyPath() async throws {
        // Only run when a screen is available — headless CI may skip.
        guard VirtualCursorController.screenCount > 0 else { return }

        let result = try await tool().execute(args: [
            "x": 0.25,
            "y": 0.75,
            "label": "Test target",
            "pulse": false,
            "hold_seconds": 0.5,
        ])
        #expect(result.text.contains("0.25"))
        #expect(result.text.contains("0.75"))
        #expect(result.text.contains("Test target"))
        #expect(result.images.isEmpty, "Point tool returns no images")

        // Clean up so the cursor doesn't linger between tests.
        VirtualCursorController.hideImmediately()
    }

    @Test("integer-style coords still parse as doubles")
    @MainActor
    func integerCoords() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }

        let result = try await tool().execute(args: ["x": 0, "y": 1])
        #expect(result.text.contains("0.000"))
        #expect(result.text.contains("1.000"))

        VirtualCursorController.hideImmediately()
    }

    // MARK: - Error Messages

    @Test("outOfRange error message mentions the valid range")
    func outOfRangeMessage() {
        let error = PointToolError.outOfRange(key: "x", value: 2.0)
        let message = error.localizedDescription
        #expect(message.contains("0") && message.contains("1"))
        #expect(message.contains("x"))
    }

    @Test("invalidDisplay error message mentions the available count")
    func invalidDisplayMessage() {
        let error = PointToolError.invalidDisplay(index: 5, available: 2)
        let message = error.localizedDescription
        #expect(message.contains("5"))
        // Available range should read as "0…1" for 2 displays.
        #expect(message.contains("1"))
    }
}
