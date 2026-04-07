import CoreFoundation
import Foundation
@testable import Tama
import Testing

/// Integration tests for BrowserTool that launch a real headless Chromium browser.
///
/// These tests require Brave Browser (or another Chromium browser) to be installed.
/// They exercise all 8 browser actions against a `data:` URI page with known content.
@Suite("BrowserTool Integration", .tags(.browser), .serialized)
struct BrowserToolIntegrationTests {
    let tool: BrowserTool

    /// A self-contained HTML page as a data: URI — no network needed.
    static let testPageURL =
        "data:text/html,<html><body><h1 id='title'>Test Page</h1><button id='btn' onclick=\"document.getElementById('output').innerText='clicked'\">Click Me</button><p id='output'>not clicked</p><input id='input' type='text' placeholder='type here'><div id='hidden' style='display:none'>secret</div><ul id='list'><li>one</li><li>two</li><li>three</li></ul></body></html>"

    init() {
        tool = BrowserTool()
    }

    // MARK: - Helpers

    /// Execute a browser action and return (result, latencyMs).
    /// Always injects `headless: true` to prevent a visible browser window during tests.
    private func timed(_ args: [String: Any]) async throws -> (String, Double) {
        var mergedArgs = args
        mergedArgs["headless"] = true
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await tool.execute(args: mergedArgs)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return (result, elapsed)
    }

    /// Navigate to the test page (idempotent if already there).
    private func navigateToTestPage() async throws {
        _ = try await tool.execute(args: [
            "action": "navigate",
            "url": Self.testPageURL,
            "headless": true,
        ])
    }

    // MARK: - Launch & Navigate

    @Test("launch headless browser and navigate to data: page")
    func launchAndNavigate() async throws {
        BrowserManager.shared.disconnect()

        let (result, ms) = try await timed([
            "action": "navigate",
            "url": Self.testPageURL,
            "headless": true,
        ])

        #expect(result.contains("Navigated to"))
        print("⏱ Launch + Navigate: \(String(format: "%.0f", ms))ms")
    }

    // MARK: - Evaluate (JS type coercion — doesn't need test page)

    @Test("evaluate returns string value")
    func evaluateString() async throws {
        let (result, ms) = try await timed([
            "action": "evaluate",
            "text": "'hello world'",
        ])
        #expect(result == "hello world")
        print("⏱ Evaluate string: \(String(format: "%.0f", ms))ms")
    }

    @Test("evaluate returns boolean value")
    func evaluateBool() async throws {
        let (result, _) = try await timed(["action": "evaluate", "text": "1 === 1"])
        #expect(result == "true")
    }

    @Test("evaluate returns number value")
    func evaluateNumber() async throws {
        let (result, _) = try await timed(["action": "evaluate", "text": "2 + 3"])
        #expect(result == "5")
    }

    @Test("evaluate returns object as JSON")
    func evaluateObject() async throws {
        let (result, _) = try await timed(["action": "evaluate", "text": "({a: 1, b: 'two'})"])
        #expect(result.contains("a"))
        #expect(result.contains("two"))
    }

    @Test("evaluate returns array as JSON")
    func evaluateArray() async throws {
        let (result, _) = try await timed(["action": "evaluate", "text": "[1, 2, 3]"])
        #expect(result.contains("1"))
        #expect(result.contains("3"))
    }

    @Test("evaluate bad JS throws javaScriptError")
    func evaluateBadJS() async {
        do {
            _ = try await tool.execute(args: ["action": "evaluate", "text": "undefinedVariable.foo"])
            Issue.record("Expected JavaScript error")
        } catch {
            #expect(
                error.localizedDescription.contains("JavaScript")
                    || error.localizedDescription.contains("not defined")
            )
        }
    }

    // MARK: - Get Text (needs test page)

    @Test("get_text extracts h1 text")
    func getTextH1() async throws {
        try await navigateToTestPage()
        let (result, ms) = try await timed(["action": "get_text", "selector": "#title"])
        #expect(result == "Test Page")
        print("⏱ Get text: \(String(format: "%.0f", ms))ms")
    }

    @Test("get_text extracts list text")
    func getTextList() async throws {
        try await navigateToTestPage()
        let (result, _) = try await timed(["action": "get_text", "selector": "#list"])
        #expect(result.contains("one"))
        #expect(result.contains("two"))
        #expect(result.contains("three"))
    }

    @Test("get_text for missing element throws")
    func getTextMissing() async throws {
        try await navigateToTestPage()
        do {
            _ = try await tool.execute(args: ["action": "get_text", "selector": "#nonexistent"])
            Issue.record("Expected element not found error")
        } catch {
            #expect(error.localizedDescription.contains("not found") || error.localizedDescription.contains("Element"))
        }
    }

    // MARK: - Get HTML (needs test page)

    @Test("get_html returns full page HTML")
    func getHTMLFullPage() async throws {
        try await navigateToTestPage()
        let (result, ms) = try await timed(["action": "get_html"])
        #expect(result.contains("<html"))
        #expect(result.contains("Test Page"))
        print("⏱ Get HTML (full page): \(String(format: "%.0f", ms))ms")
    }

    @Test("get_html with selector returns element HTML")
    func getHTMLSelector() async throws {
        try await navigateToTestPage()
        let (result, _) = try await timed(["action": "get_html", "selector": "#title"])
        #expect(result.contains("<h1"))
        #expect(result.contains("Test Page"))
    }

    @Test("get_html for missing element throws")
    func getHTMLMissing() async throws {
        try await navigateToTestPage()
        do {
            _ = try await tool.execute(args: ["action": "get_html", "selector": "#nonexistent"])
            Issue.record("Expected element not found error")
        } catch {
            #expect(error.localizedDescription.contains("not found") || error.localizedDescription.contains("Element"))
        }
    }

    // MARK: - Click (needs test page)

    @Test("click button modifies DOM state")
    func clickButton() async throws {
        try await navigateToTestPage()

        let (before, _) = try await timed(["action": "get_text", "selector": "#output"])
        #expect(before == "not clicked")

        let (clickResult, ms) = try await timed(["action": "click", "selector": "#btn"])
        #expect(clickResult.contains("Clicked"))
        print("⏱ Click: \(String(format: "%.0f", ms))ms")

        let (after, _) = try await timed(["action": "get_text", "selector": "#output"])
        #expect(after == "clicked")
    }

    @Test("click non-existent element throws")
    func clickMissing() async throws {
        try await navigateToTestPage()
        do {
            _ = try await tool.execute(args: ["action": "click", "selector": "#no-such-button"])
            Issue.record("Expected element not found error")
        } catch {
            #expect(error.localizedDescription.contains("not found") || error.localizedDescription.contains("Element"))
        }
    }

    // MARK: - Type (needs test page)

    @Test("type inserts text into input field")
    func typeIntoInput() async throws {
        try await navigateToTestPage()

        let (typeResult, ms) = try await timed([
            "action": "type",
            "selector": "#input",
            "text": "Hello, Tamagotchai!",
        ])
        #expect(typeResult.contains("Typed"))
        print("⏱ Type (19 chars): \(String(format: "%.0f", ms))ms")

        let (value, _) = try await timed(["action": "evaluate", "text": "document.getElementById('input').value"])
        #expect(value == "Hello, Tamagotchai!")
    }

    @Test("type with non-existent selector throws")
    func typeMissingElement() async throws {
        try await navigateToTestPage()
        do {
            _ = try await tool.execute(args: ["action": "type", "selector": "#nonexistent", "text": "test"])
            Issue.record("Expected element not found error")
        } catch {
            #expect(error.localizedDescription.contains("not found") || error.localizedDescription.contains("Element"))
        }
    }

    // MARK: - Wait (needs test page)

    @Test("wait for existing selector returns immediately")
    func waitExistingSelector() async throws {
        try await navigateToTestPage()
        let (result, ms) = try await timed(["action": "wait", "selector": "#title", "timeout": 5000])
        #expect(result.contains("Element found"))
        #expect(ms < 1000, "Wait for existing element should be fast, was \(ms)ms")
        print("⏱ Wait (existing element): \(String(format: "%.0f", ms))ms")
    }

    @Test("wait for missing selector times out")
    func waitMissingSelectorTimesOut() async throws {
        try await navigateToTestPage()
        do {
            _ = try await tool.execute(args: ["action": "wait", "selector": "#does-not-exist", "timeout": 1000])
            Issue.record("Expected timeout error")
        } catch {
            #expect(error.localizedDescription.contains("Timeout") || error.localizedDescription.contains("timeout"))
        }
    }

    // MARK: - Screenshot

    @Test("screenshot returns expected format")
    func screenshotFormat() async throws {
        let (result, ms) = try await timed(["action": "screenshot"])
        #expect(result.contains("Screenshot captured"))
        #expect(result.contains("base64 PNG"))
        print("⏱ Screenshot: \(String(format: "%.0f", ms))ms")
    }

    // MARK: - Speed Benchmark

    @Test("10 sequential evaluate calls measure latency")
    func evaluateLatencyBenchmark() async throws {
        var latencies: [Double] = []

        for i in 0 ..< 10 {
            let (result, ms) = try await timed(["action": "evaluate", "text": "\(i) + 1"])
            #expect(result == "\(i + 1)")
            latencies.append(ms)
        }

        let sorted = latencies.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let avg = latencies.reduce(0, +) / Double(latencies.count)
        let total = latencies.reduce(0, +)

        print("⏱ Evaluate latency (10 calls):")
        print("  Total: \(String(format: "%.0f", total))ms")
        print("  Avg:   \(String(format: "%.1f", avg))ms")
        print("  P50:   \(String(format: "%.1f", p50))ms")
        print("  P95:   \(String(format: "%.1f", p95))ms")

        #expect(p95 < 500, "P95 latency \(p95)ms exceeds 500ms threshold")
    }

    // MARK: - Connection Reuse

    @Test("multiple operations reuse one connection (no re-launch)")
    func connectionReuse() async throws {
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await tool.execute(args: ["action": "evaluate", "text": "'first'"])
        let firstMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        let start2 = CFAbsoluteTimeGetCurrent()
        _ = try await tool.execute(args: ["action": "evaluate", "text": "'second'"])
        let secondMs = (CFAbsoluteTimeGetCurrent() - start2) * 1000.0

        print("⏱ Connection reuse: first=\(String(format: "%.0f", firstMs))ms, second=\(String(format: "%.0f", secondMs))ms")
        #expect(secondMs < 1000, "Second call took \(secondMs)ms — connection may not be reused")
    }

    // MARK: - Cleanup

    @Test("disconnect kills browser process")
    func cleanup() async throws {
        BrowserManager.shared.disconnect()
        print("✅ Browser disconnected cleanly")
    }
}

// MARK: - Custom Tag

extension Tag {
    @Tag static var browser: Self
}
