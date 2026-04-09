@testable import Tama
import Testing

@Suite("ClaudeModels")
struct ClaudeModelsTests {
    @Test("textContent returns only text from mixed content blocks")
    func textContentWithMixedBlocks() {
        let response = ClaudeResponse(
            content: [
                .text("Hello "),
                .toolUse(id: "t1", name: "bash", input: ["command": "ls"]),
                .text("world"),
            ],
            stopReason: "end_turn",
            reasoningContent: nil
        )
        #expect(response.textContent == "Hello world")
    }

    @Test("toolUseCalls filters only toolUse blocks")
    func toolUseCallsFiltering() {
        let response = ClaudeResponse(
            content: [
                .text("Some text"),
                .toolUse(id: "t1", name: "bash", input: ["command": "ls"]),
                .toolUse(id: "t2", name: "read", input: ["file_path": "a.txt"]),
            ],
            stopReason: "tool_use",
            reasoningContent: nil
        )
        let calls = response.toolUseCalls
        #expect(calls.count == 2)
        #expect(calls[0].id == "t1")
        #expect(calls[0].name == "bash")
        #expect(calls[1].id == "t2")
        #expect(calls[1].name == "read")
    }

    @Test("empty response returns empty string and empty array")
    func emptyResponse() {
        let response = ClaudeResponse(content: [], stopReason: nil, reasoningContent: nil)
        #expect(response.textContent == "")
        #expect(response.toolUseCalls.isEmpty)
    }

    @Test("textContent joins multiple text blocks without separator")
    func textContentJoinsBlocks() {
        let response = ClaudeResponse(
            content: [.text("abc"), .text("def"), .text("ghi")],
            stopReason: "end_turn",
            reasoningContent: nil
        )
        #expect(response.textContent == "abcdefghi")
    }
}
