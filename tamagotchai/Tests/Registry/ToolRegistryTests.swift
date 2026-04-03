import Foundation
import Testing
@testable import Tamagotchai

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("defaultRegistry creates all 13 tools")
    func defaultRegistryHasAllTools() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        #expect(registry.tools.count == 13)
    }

    @Test("tool(named:) returns correct tool")
    func toolNamedReturnsCorrectTool() {
        let registry = ToolRegistry.defaultRegistry(workingDirectory: NSTemporaryDirectory())
        let expectedNames = [
            "bash", "read", "write", "edit", "ls", "find", "grep", "web_fetch",
            "create_reminder", "create_routine", "list_schedules", "delete_schedule", "dismiss",
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
        #expect(definitions.count == 13)

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
            #expect(schema["type"] as? String == "object", "Schema type should be 'object' for \(def["name"] ?? "unknown")")
            #expect(schema["properties"] is [String: Any], "Schema should have 'properties' for \(def["name"] ?? "unknown")")
        }
    }
}
