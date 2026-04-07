import Foundation
import Testing
@testable import Tama

@Suite("StreamParser")
struct StreamParserTests {
    // StreamParser.processLine is private and AsyncBytes can't be easily mocked,
    // so we test the parser's public API (buildResponse) and the model types directly.

    @Test("buildResponse returns empty response when no data fed")
    @MainActor func buildResponseStructure() {
        let parser = StreamParser { _ in }
        let response = parser.buildResponse()
        #expect(response.content.isEmpty)
        #expect(response.stopReason == nil)
    }

    @Test("StreamEvent textDelta carries text")
    func streamEventTextDelta() {
        let event = StreamEvent.textDelta("Hello")
        if case let .textDelta(text) = event {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected textDelta event")
        }
    }

    @Test("StreamEvent toolUseStart carries id and name")
    func streamEventToolUseStart() {
        let event = StreamEvent.toolUseStart(id: "tool_1", name: "bash")
        if case let .toolUseStart(id, name) = event {
            #expect(id == "tool_1")
            #expect(name == "bash")
        } else {
            Issue.record("Expected toolUseStart event")
        }
    }

    @Test("ContentBlock text extraction")
    func contentBlockTextExtraction() {
        let block = ContentBlock.text("Hello world")
        if case let .text(text) = block {
            #expect(text == "Hello world")
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("ContentBlock toolUse extraction")
    func contentBlockToolUseExtraction() {
        let block = ContentBlock.toolUse(id: "t1", name: "read", input: ["file_path": "test.txt"])
        if case let .toolUse(id, name, input) = block {
            #expect(id == "t1")
            #expect(name == "read")
            #expect(input["file_path"] as? String == "test.txt")
        } else {
            Issue.record("Expected toolUse block")
        }
    }

    // Tests for serverToolUse, serverToolResult, serverToolResultError removed —
    // those ContentBlock cases were removed from the source.
}
