@testable import Tama
import Testing

@Suite("BrowserTool Validation")
struct BrowserToolTests {
    let tool: BrowserTool

    init() {
        tool = BrowserTool()
    }

    // MARK: - Input Schema

    @Test("input schema has correct structure")
    func inputSchemaStructure() {
        let schema = tool.inputSchema
        #expect(schema["type"] as? String == "object")

        let properties = schema["properties"] as? [String: Any]
        #expect(properties != nil)
        #expect(properties?["action"] != nil, "Schema must have 'action' property")
        #expect(properties?["url"] != nil, "Schema must have 'url' property")
        #expect(properties?["selector"] != nil, "Schema must have 'selector' property")
        #expect(properties?["text"] != nil, "Schema must have 'text' property")
        #expect(properties?["headless"] != nil, "Schema must have 'headless' property")
        #expect(properties?["timeout"] != nil, "Schema must have 'timeout' property")

        let required = schema["required"] as? [String]
        #expect(required == ["action"])
    }

    @Test("action enum lists all 8 actions")
    func actionEnumCompleteness() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let actionProp = properties?["action"] as? [String: Any]
        let enumValues = actionProp?["enum"] as? [String]
        #expect(enumValues != nil)
        #expect(enumValues?.count == 8)
        let expected = Set(["navigate", "click", "type", "get_text", "get_html", "screenshot", "evaluate", "wait"])
        #expect(Set(enumValues ?? []) == expected)
    }

    @Test("name is 'browser'")
    func toolName() {
        #expect(tool.name == "browser")
    }

    // MARK: - Missing Action (checked before browser connection)

    @Test("missing action throws error")
    func missingAction() async {
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected error for missing action")
        } catch {
            #expect(error.localizedDescription.contains("action"))
        }
    }

    @Test("missing action with other params still throws")
    func missingActionWithOtherParams() async {
        do {
            _ = try await tool.execute(args: ["url": "https://example.com"])
            Issue.record("Expected error for missing action")
        } catch {
            #expect(error.localizedDescription.contains("action"))
        }
    }

    // MARK: - Missing Parameter Validation (checked before browser connection)

    @Test("navigate missing url param throws")
    func navigateMissingURL() async {
        do {
            _ = try await tool.execute(args: ["action": "navigate"])
            Issue.record("Expected missing parameter error")
        } catch {
            #expect(error.localizedDescription.contains("url") || error.localizedDescription.contains("parameter"))
        }
    }

    @Test("click missing selector param throws")
    func clickMissingSelector() async {
        do {
            _ = try await tool.execute(args: ["action": "click"])
            Issue.record("Expected missing parameter error")
        } catch {
            #expect(error.localizedDescription.contains("selector") || error.localizedDescription.contains("parameter"))
        }
    }

    @Test("type missing text param throws")
    func typeMissingText() async {
        do {
            _ = try await tool.execute(args: ["action": "type", "selector": "#input"])
            Issue.record("Expected missing parameter error")
        } catch {
            #expect(error.localizedDescription.contains("text") || error.localizedDescription.contains("parameter"))
        }
    }

    @Test("evaluate missing text param throws")
    func evaluateMissingText() async {
        do {
            _ = try await tool.execute(args: ["action": "evaluate"])
            Issue.record("Expected missing parameter error")
        } catch {
            #expect(error.localizedDescription.contains("text") || error.localizedDescription.contains("parameter"))
        }
    }

    @Test("wait missing selector param throws")
    func waitMissingSelector() async {
        do {
            _ = try await tool.execute(args: ["action": "wait"])
            Issue.record("Expected missing parameter error")
        } catch {
            #expect(error.localizedDescription.contains("selector") || error.localizedDescription.contains("parameter"))
        }
    }

    // MARK: - Error Enum Coverage

    @Test("BrowserToolError descriptions are informative")
    func errorDescriptions() {
        let cases: [(BrowserToolError, String)] = [
            (.missingParameter("url"), "url"),
            (.elementNotFound("#btn"), "#btn"),
            (.navigationFailed("net::ERR_NAME_NOT_RESOLVED"), "net::ERR_NAME_NOT_RESOLVED"),
            (.javaScriptError("ReferenceError: x is not defined"), "ReferenceError"),
            (.timeout("Waiting for selector: #gone"), "#gone"),
        ]

        for (error, expected) in cases {
            let desc = error.localizedDescription
            #expect(desc.contains(expected), "Error '\(error)' should mention '\(expected)', got: \(desc)")
        }
    }

    @Test("CDPError descriptions are informative")
    func cdpErrorDescriptions() {
        #expect(CDPError.notConnected.localizedDescription.contains("Not connected"))
        #expect(CDPError.disconnected.localizedDescription.contains("closed"))
        #expect(CDPError.commandFailed("test").localizedDescription.contains("test"))
    }

    @Test("BrowserManagerError descriptions are informative")
    func browserManagerErrorDescriptions() {
        #expect(BrowserManagerError.noBrowserFound("Chrome, Brave").localizedDescription.contains("Chrome"))
        #expect(BrowserManagerError.launchFailed("permission denied").localizedDescription.contains("permission"))
        #expect(BrowserManagerError.launchTimeout.localizedDescription.contains("timed out"))
    }
}
