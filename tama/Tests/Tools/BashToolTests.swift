import Foundation
@testable import Tama
import Testing

@Suite("BashTool")
struct BashToolTests {
    let tool: BashTool

    init() {
        tool = BashTool(workingDirectory: NSTemporaryDirectory())
    }

    @Test("echo hello returns exit code 0 and output")
    func echoHello() async throws {
        let result = try await tool.execute(args: ["command": "echo hello"])
        #expect(result.contains("Exit code: 0"))
        #expect(result.contains("hello"))
    }

    @Test("failing command returns non-zero exit code")
    func failingCommand() async throws {
        let result = try await tool.execute(args: ["command": "exit 42"])
        #expect(result.contains("Exit code: 42"))
    }

    @Test("short timeout causes timeout message")
    func shortTimeout() async throws {
        let result = try await tool.execute(args: ["command": "sleep 10", "timeout": 500])
        #expect(result.contains("timed out"))
    }

    @Test("output truncation with large output")
    func outputTruncation() async throws {
        // Generate more than 2000 lines
        let result = try await tool.execute(args: ["command": "seq 1 3000"])
        #expect(result.contains("truncated"))
    }

    @Test("missing command throws error")
    func missingCommandThrows() async throws {
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected error for missing command")
        } catch {
            #expect(error.localizedDescription.contains("command"))
        }
    }

    @Test("captures stderr output")
    func capturesStderr() async throws {
        let result = try await tool.execute(args: ["command": "echo error >&2"])
        #expect(result.contains("error"))
    }
}
