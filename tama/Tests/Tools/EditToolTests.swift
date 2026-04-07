import Foundation
import Testing
@testable import Tama

@Suite("EditTool")
struct EditToolTests {
    let tempDir: String
    let tool: EditTool

    init() throws {
        tempDir = NSTemporaryDirectory() + "EditToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        tool = EditTool(workingDirectory: tempDir)
    }

    private func writeFile(_ name: String, content: String) throws {
        let path = (tempDir as NSString).appendingPathComponent(name)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func readFile(_ name: String) throws -> String {
        let path = (tempDir as NSString).appendingPathComponent(name)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("single occurrence replacement produces diff output")
    func singleReplacement() async throws {
        try writeFile("edit.txt", content: "Hello world\nfoo bar\nbaz qux\n")
        let result = try await tool.execute(args: [
            "file_path": "edit.txt",
            "old_text": "foo bar",
            "new_text": "FOO BAR",
        ])
        #expect(result.contains("-foo bar"))
        #expect(result.contains("+FOO BAR"))
        let content = try readFile("edit.txt")
        #expect(content.contains("FOO BAR"))
        #expect(!content.contains("foo bar"))
        cleanup()
    }

    @Test("old_text not found throws error")
    func notFoundThrows() async throws {
        try writeFile("nf.txt", content: "Hello world\n")
        do {
            _ = try await tool.execute(args: [
                "file_path": "nf.txt",
                "old_text": "nonexistent text",
                "new_text": "replacement",
            ])
            Issue.record("Expected error for text not found")
        } catch {
            #expect(error.localizedDescription.contains("not found"))
        }
        cleanup()
    }

    @Test("multiple matches throws error with count")
    func multipleMatchesThrows() async throws {
        try writeFile("multi.txt", content: "aaa\nbbb\naaa\n")
        do {
            _ = try await tool.execute(args: [
                "file_path": "multi.txt",
                "old_text": "aaa",
                "new_text": "ccc",
            ])
            Issue.record("Expected error for multiple matches")
        } catch {
            #expect(error.localizedDescription.contains("2"))
        }
        cleanup()
    }

    @Test("CRLF normalization works")
    func crlfNormalization() async throws {
        try writeFile("crlf.txt", content: "line1\r\nline2\r\nline3\r\n")
        let result = try await tool.execute(args: [
            "file_path": "crlf.txt",
            "old_text": "line2",
            "new_text": "LINE2",
        ])
        #expect(result.contains("+LINE2"))
        cleanup()
    }

    @Test("missing file_path parameter throws")
    func missingFilePathThrows() async throws {
        do {
            _ = try await tool.execute(args: ["old_text": "a", "new_text": "b"])
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("file_path"))
        }
    }

    @Test("missing old_text parameter throws")
    func missingOldTextThrows() async throws {
        do {
            _ = try await tool.execute(args: ["file_path": "x.txt", "new_text": "b"])
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("old_text"))
        }
    }

    @Test("missing new_text parameter throws")
    func missingNewTextThrows() async throws {
        do {
            _ = try await tool.execute(args: ["file_path": "x.txt", "old_text": "a"])
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("new_text"))
        }
    }
}
