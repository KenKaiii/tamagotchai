import Foundation
@testable import Tama
import Testing

@Suite("ReadTool")
struct ReadToolTests {
    let tempDir: String
    let tool: ReadTool

    init() throws {
        tempDir = NSTemporaryDirectory() + "ReadToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        tool = ReadTool(workingDirectory: tempDir)
    }

    // Helper to write a test file
    private func writeFile(_ name: String, content: String) throws {
        let path = (tempDir as NSString).appendingPathComponent(name)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // Helper to clean up
    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("reads a normal file with numbered lines")
    func readNormalFile() async throws {
        try writeFile("test.txt", content: "line one\nline two\nline three\n")
        let result = try await tool.execute(args: ["file_path": "test.txt"])
        #expect(result.contains("1\tline one"))
        #expect(result.contains("2\tline two"))
        #expect(result.contains("3\tline three"))
        cleanup()
    }

    @Test("reads with offset parameter")
    func readWithOffset() async throws {
        try writeFile("offset.txt", content: "a\nb\nc\nd\ne\n")
        let result = try await tool.execute(args: ["file_path": "offset.txt", "offset": 3])
        #expect(!result.contains("1\ta"))
        #expect(!result.contains("2\tb"))
        #expect(result.contains("3\tc"))
        #expect(result.contains("4\td"))
        #expect(result.contains("5\te"))
        cleanup()
    }

    @Test("reads with limit parameter")
    func readWithLimit() async throws {
        try writeFile("limit.txt", content: "a\nb\nc\nd\ne\n")
        let result = try await tool.execute(args: ["file_path": "limit.txt", "limit": 2])
        #expect(result.contains("1\ta"))
        #expect(result.contains("2\tb"))
        #expect(!result.contains("3\tc"))
        cleanup()
    }

    @Test("reads with offset and limit")
    func readWithOffsetAndLimit() async throws {
        try writeFile("both.txt", content: "a\nb\nc\nd\ne\n")
        let result = try await tool.execute(args: ["file_path": "both.txt", "offset": 2, "limit": 2])
        #expect(!result.contains("1\ta"))
        #expect(result.contains("2\tb"))
        #expect(result.contains("3\tc"))
        #expect(!result.contains("4\td"))
        cleanup()
    }

    @Test("detects binary file by extension")
    func detectBinaryFile() async throws {
        try writeFile("image.jpg", content: "not really an image")
        let result = try await tool.execute(args: ["file_path": "image.jpg"])
        #expect(result.contains("Binary file detected"))
        cleanup()
    }

    @Test("throws for missing file")
    func missingFileThrows() async throws {
        do {
            _ = try await tool.execute(args: ["file_path": "nonexistent.txt"])
            Issue.record("Expected error for missing file")
        } catch {
            #expect(error.localizedDescription.contains("Failed to read file"))
        }
        cleanup()
    }

    @Test("throws for missing file_path argument")
    func missingArgumentThrows() async throws {
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected error for missing argument")
        } catch {
            #expect(error.localizedDescription.contains("file_path"))
        }
    }

    @Test("handles file without trailing newline")
    func fileWithoutTrailingNewline() async throws {
        try writeFile("notail.txt", content: "only line")
        let result = try await tool.execute(args: ["file_path": "notail.txt"])
        #expect(result.contains("1\tonly line"))
        cleanup()
    }
}
