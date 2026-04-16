import Foundation
@testable import Tama
import Testing

@Suite("GrepTool")
struct GrepToolTests {
    let tempDir: String
    let tool: GrepTool

    init() throws {
        tempDir = NSTemporaryDirectory() + "GrepToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        tool = GrepTool(workingDirectory: tempDir)
    }

    private func writeFile(_ name: String, content: String) throws {
        let path = (tempDir as NSString).appendingPathComponent(name)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("regex pattern finds matches with line numbers")
    func regexPatternFindsMatches() async throws {
        try writeFile("test.txt", content: "apple\nbanana\napricot\ncherry\n")
        let result = try await tool.execute(args: ["pattern": "ap"]).text
        #expect(result.contains("test.txt:1:apple"))
        #expect(result.contains("test.txt:3:apricot"))
        #expect(!result.contains("banana"))
        cleanup()
    }

    @Test("case insensitive flag works")
    func caseInsensitiveSearch() async throws {
        try writeFile("case.txt", content: "Hello\nhello\nHELLO\nworld\n")
        let result = try await tool.execute(args: ["pattern": "hello", "case_insensitive": true]).text
        #expect(result.contains("case.txt:1:Hello"))
        #expect(result.contains("case.txt:2:hello"))
        #expect(result.contains("case.txt:3:HELLO"))
        cleanup()
    }

    @Test("include glob filters files")
    func includeGlobFilters() async throws {
        try writeFile("code.swift", content: "let x = 1\n")
        try writeFile("notes.md", content: "let x = 1\n")
        let result = try await tool.execute(args: ["pattern": "let", "include": "*.swift"]).text
        #expect(result.contains("code.swift"))
        #expect(!result.contains("notes.md"))
        cleanup()
    }

    @Test("max_results cap")
    func maxResultsCap() async throws {
        var lines = ""
        for i in 1 ... 20 {
            lines += "match line \(i)\n"
        }
        try writeFile("many.txt", content: lines)
        let result = try await tool.execute(args: ["pattern": "match", "max_results": 5]).text
        // Should mention total matches found
        #expect(result.contains("20 match(es) found"))
        cleanup()
    }

    @Test("no matches returns message")
    func noMatchesReturnsMessage() async throws {
        try writeFile("empty.txt", content: "nothing here\n")
        let result = try await tool.execute(args: ["pattern": "zzzzz"]).text
        #expect(result.contains("No matches found"))
        cleanup()
    }

    @Test("invalid regex throws error")
    func invalidRegexThrows() async throws {
        try writeFile("dummy.txt", content: "text\n")
        do {
            _ = try await tool.execute(args: ["pattern": "[invalid"])
            Issue.record("Expected error for invalid regex")
        } catch {
            #expect(error.localizedDescription.contains("Invalid regex"))
        }
        cleanup()
    }
}
