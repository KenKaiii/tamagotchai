import Foundation
import Testing
@testable import Tama

@Suite("WebFetchTool SSRF Validation")
struct WebFetchToolTests {
    let tool: WebFetchTool

    init() {
        tool = WebFetchTool()
    }

    @Test("blocks localhost")
    func blocksLocalhost() async {
        do {
            _ = try await tool.execute(args: ["url": "http://localhost:8080/secret"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 127.0.0.1")
    func blocksLoopback() async {
        do {
            _ = try await tool.execute(args: ["url": "http://127.0.0.1/admin"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 10.x.x.x private range")
    func blocks10Range() async {
        do {
            _ = try await tool.execute(args: ["url": "http://10.0.0.1/internal"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 172.16-31.x.x private range")
    func blocks172Range() async {
        do {
            _ = try await tool.execute(args: ["url": "http://172.16.0.1/internal"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("blocks 192.168.x.x private range")
    func blocks192Range() async {
        do {
            _ = try await tool.execute(args: ["url": "http://192.168.1.1/router"])
            Issue.record("Expected blocked host error")
        } catch {
            #expect(error.localizedDescription.contains("Blocked host"))
        }
    }

    @Test("missing URL parameter throws")
    func missingURLThrows() async {
        do {
            _ = try await tool.execute(args: [:])
            Issue.record("Expected missing URL error")
        } catch {
            #expect(error.localizedDescription.contains("url"))
        }
    }

    @Test("invalid URL throws")
    func invalidURLThrows() async {
        do {
            _ = try await tool.execute(args: ["url": "not a url at all %%%"])
            Issue.record("Expected invalid URL error")
        } catch {
            #expect(error.localizedDescription.contains("Invalid URL"))
        }
    }
}
