import Foundation
@testable import Tama
import Testing

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("defaultRegistry creates all 19 tools")
    func defaultRegistryHasAllTools() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        #expect(registry.tools.count == 19)
    }

    @Test("tool(named:) returns correct tool")
    func toolNamedReturnsCorrectTool() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        let expectedNames = [
            "bash", "read", "write", "edit", "ls", "find", "grep", "web_fetch", "web_search",
            "create_reminder", "create_routine", "list_schedules", "delete_schedule",
            "task", "dismiss", "browser", "screenshot", "point", "skill",
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
        #expect(definitions.count == 19)

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

    @Test("callRegistry has point tool so the voice agent can guide the user visually")
    func callRegistryHasPoint() {
        let registry = ToolRegistry.callRegistry(workingDirectory: NSTemporaryDirectory())
        #expect(registry.tool(named: "point") != nil)
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

    @Test("callSystemPrompt teaches the see-point-explain pattern with trigger phrases")
    @MainActor
    func callPromptTeachesSeePointExplain() {
        // The voice agent's main value-add is visual guidance. The prompt must
        // both enumerate the natural trigger phrases the user says, AND instruct
        // the agent to start the screenshot → point loop without being explicitly
        // asked. Asserting the prompt structure here prevents future edits from
        // quietly regressing the UX back to "take a screenshot and point at X".
        let prompt = buildCallSystemPrompt().lowercased()
        #expect(prompt.contains("point"), "Call prompt must name the point tool")
        #expect(prompt.contains("where"), "Call prompt must list 'where's X' as a trigger")
        #expect(prompt.contains("how do i"), "Call prompt must list 'how do I X' as a trigger")
        #expect(
            prompt.contains("don't wait") || prompt.contains("proactively") || prompt.contains("just do it"),
            "Call prompt must push the agent to invoke the pattern without being asked"
        )
        #expect(
            prompt.contains("narrate") || prompt.contains("say") || prompt.contains("out loud"),
            "Call prompt must instruct the agent to narrate while pointing"
        )
    }

    @Test("baseSystemPrompt teaches the see-point-explain pattern with trigger phrases")
    func basePromptTeachesSeePointExplain() {
        // Same coverage for the chat-panel prompt — text chats also benefit from
        // pointing when the user is in front of their screen.
        let prompt = baseSystemPrompt.lowercased()
        #expect(prompt.contains("point"), "Base prompt must name the point tool")
        #expect(prompt.contains("where"), "Base prompt must list 'where's X' as a trigger")
        #expect(prompt.contains("how do i"), "Base prompt must list 'how do I X' as a trigger")
    }
}
