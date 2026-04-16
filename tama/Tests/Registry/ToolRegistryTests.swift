import Foundation
@testable import Tama
import Testing

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("defaultRegistry creates all 18 tools")
    func defaultRegistryHasAllTools() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        #expect(registry.tools.count == 18)
    }

    @Test("tool(named:) returns correct tool")
    func toolNamedReturnsCorrectTool() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        let expectedNames = [
            "bash", "read", "write", "edit", "ls", "find", "grep", "web_fetch", "web_search",
            "create_reminder", "create_routine", "list_schedules", "delete_schedule",
            "task", "dismiss", "browser", "screenshot", "skill",
        ]
        for name in expectedNames {
            let tool = registry.tool(named: name)
            #expect(tool != nil, "Expected tool named '\(name)' to exist")
            #expect(tool?.name == name)
        }
    }

    @Test("tool(named:) returns nil for unknown name")
    func toolNamedReturnsNilForUnknown() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        #expect(registry.tool(named: "nonexistent") == nil)
    }

    @Test("apiToolDefinitions returns correct schema shape")
    func apiToolDefinitionsShape() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        let definitions = registry.apiToolDefinitions()
        #expect(definitions.count == 18)

        for def in definitions {
            #expect(def["name"] is String, "Each definition must have a 'name' string")
            #expect(def["description"] is String, "Each definition must have a 'description' string")
            #expect(def["input_schema"] is [String: Any], "Each definition must have an 'input_schema' dict")
        }
    }

    @Test("apiToolDefinitions input_schema has type and properties")
    func apiToolDefinitionsSchemaContent() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        let definitions = registry.apiToolDefinitions()

        for def in definitions {
            guard let schema = def["input_schema"] as? [String: Any] else {
                Issue.record("Missing input_schema for \(def["name"] ?? "unknown")")
                continue
            }
            #expect(
                schema["type"] as? String == "object",
                "Schema type should be 'object' for \(def["name"] ?? "unknown")"
            )
            #expect(
                schema["properties"] is [String: Any],
                "Schema should have 'properties' for \(def["name"] ?? "unknown")"
            )
        }
    }

    // MARK: - Call Registry (voice agent)

    @Test("callRegistry has screenshot tool so the voice agent can see the user's screen")
    func callRegistryHasScreenshot() {
        let registry = ToolRegistry.callRegistry(workingDirectory: NSTemporaryDirectory())
        #expect(registry.tool(named: "screenshot") != nil)
    }

    @Test("callRegistry swaps `dismiss` for `end_call` but keeps every other tool")
    func callRegistryDifferences() {
        let defaults = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        let call = ToolRegistry.callRegistry(workingDirectory: NSTemporaryDirectory())

        #expect(call.tools.count == defaults.tools.count)
        #expect(call.tool(named: "dismiss") == nil, "Voice agent must not have the chat-dismiss tool")
        #expect(call.tool(named: "end_call") != nil, "Voice agent must have end_call instead")

        // Every non-dismiss tool from the default registry should also be in the call registry.
        let shared = defaults.tools.map(\.name).filter { $0 != "dismiss" }
        for name in shared {
            #expect(call.tool(named: name) != nil, "Call registry missing shared tool '\(name)'")
        }
    }

    @Test("callSystemPrompt mentions the screenshot tool and voice-specific guidance")
    @MainActor
    func callPromptMentionsScreenshot() {
        let prompt = buildCallSystemPrompt()
        #expect(prompt.contains("screenshot"), "Call prompt must name the screenshot tool")
        // Voice-specific guidance: agent should skip path/bytes aloud.
        #expect(
            prompt.contains("file path") || prompt.contains("byte"),
            "Call prompt should instruct the agent to skip path/bytes when speaking"
        )
    }
}
