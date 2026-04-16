import Foundation
@testable import Tama
import Testing

@Suite("FindTool")
struct FindToolTests {
    let tempDir: String
    let tool: FindTool

    init() throws {
        tempDir = NSTemporaryDirectory() + "FindToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        tool = FindTool(workingDirectory: tempDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    @Test("glob pattern matches expected files")
    func globPatternMatches() async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (tempDir as NSString).appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try "code".write(
            toFile: (tempDir as NSString).appendingPathComponent("src/main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "code".write(
            toFile: (tempDir as NSString).appendingPathComponent("src/helper.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "text".write(
            toFile: (tempDir as NSString).appendingPathComponent("src/readme.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await tool.execute(args: ["pattern": "*.swift"]).text
        #expect(result.contains("main.swift"))
        #expect(result.contains("helper.swift"))
        #expect(!result.contains("readme.md"))
        cleanup()
    }

    @Test("ignored directories are skipped")
    func ignoredDirectoriesSkipped() async throws {
        let fm = FileManager.default
        let gitDir = (tempDir as NSString).appendingPathComponent(".git")
        try fm.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        try "data".write(
            toFile: (gitDir as NSString).appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try "code".write(
            toFile: (tempDir as NSString).appendingPathComponent("app.swift"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await tool.execute(args: ["pattern": "*"]).text
        #expect(result.contains("app.swift"))
        #expect(!result.contains("config"))
        cleanup()
    }

    @Test("no matches returns message")
    func noMatchesReturnsMessage() async throws {
        let result = try await tool.execute(args: ["pattern": "*.xyz"]).text
        #expect(result.contains("No files found"))
        cleanup()
    }

    @Test("max 100 results cap")
    func maxResultsCap() async throws {
        let fm = FileManager.default
        let subdir = (tempDir as NSString).appendingPathComponent("many")
        try fm.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        for i in 0 ..< 120 {
            try "x".write(
                toFile: (subdir as NSString).appendingPathComponent("file\(String(format: "%03d", i)).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let result = try await tool.execute(args: ["pattern": "*.txt"]).text
        #expect(result.contains("100 of"))
        cleanup()
    }
}
