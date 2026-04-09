import Foundation
@testable import Tama
import Testing

@Suite("WriteTool")
struct WriteToolTests {
    let tempDir: String
    let tool: WriteTool

    init() throws {
        tempDir = NSTemporaryDirectory() + "WriteToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        tool = WriteTool(workingDirectory: tempDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("writes new file with correct content")
    func writeNewFile() async throws {
        let result = try await tool.execute(args: ["file_path": "hello.txt", "content": "Hello, world!"])
        #expect(result.contains("Wrote"))
        let written = try String(
            contentsOfFile: (tempDir as NSString).appendingPathComponent("hello.txt"),
            encoding: .utf8
        )
        #expect(written == "Hello, world!")
        cleanup()
    }

    @Test("creates parent directories")
    func createParentDirs() async throws {
        let result = try await tool.execute(args: ["file_path": "a/b/c/deep.txt", "content": "deep content"])
        #expect(result.contains("Wrote"))
        let path = (tempDir as NSString).appendingPathComponent("a/b/c/deep.txt")
        #expect(FileManager.default.fileExists(atPath: path))
        cleanup()
    }

    @Test("overwrites existing file")
    func overwriteExisting() async throws {
        _ = try await tool.execute(args: ["file_path": "over.txt", "content": "original"])
        _ = try await tool.execute(args: ["file_path": "over.txt", "content": "replaced"])
        let content = try String(
            contentsOfFile: (tempDir as NSString).appendingPathComponent("over.txt"),
            encoding: .utf8
        )
        #expect(content == "replaced")
        cleanup()
    }

    @Test("throws for missing content parameter")
    func missingContentThrows() async throws {
        do {
            _ = try await tool.execute(args: ["file_path": "test.txt"])
            Issue.record("Expected error for missing content")
        } catch {
            #expect(error.localizedDescription.contains("content"))
        }
    }

    @Test("throws for missing file_path parameter")
    func missingFilePathThrows() async throws {
        do {
            _ = try await tool.execute(args: ["content": "text"])
            Issue.record("Expected error for missing file_path")
        } catch {
            #expect(error.localizedDescription.contains("file_path"))
        }
    }
}
