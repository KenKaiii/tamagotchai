import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.browser"
)

/// Agent tool that controls a Chromium browser via the Chrome DevTools Protocol.
///
/// Single tool with an `action` parameter that dispatches to high-level browser operations:
/// navigate, click, type, get_text, get_html, screenshot, evaluate, wait.
final class BrowserTool: AgentTool {
    let name = "browser"

    let description = """
    Control a Chromium-based browser (Chrome, Brave, Edge, Arc, Vivaldi, Opera) \
    via the Chrome DevTools Protocol. Supports navigating to URLs, clicking elements, \
    typing text, extracting page content, taking screenshots, and evaluating JavaScript.
    """

    private static let defaultTimeoutMs = 30000

    init() {}

    // MARK: - Input Schema

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["navigate", "click", "type", "get_text", "get_html", "screenshot", "evaluate", "wait"],
                    "description": "The browser action to perform.",
                ],
                "url": [
                    "type": "string",
                    "description": "URL to navigate to (navigate action).",
                ],
                "selector": [
                    "type": "string",
                    "description": "CSS selector for element targeting.",
                ],
                "text": [
                    "type": "string",
                    "description": "Text to type (type action) or JavaScript to evaluate (evaluate action).",
                ],
                "headless": [
                    "type": "boolean",
                    "description": "Run browser in headless mode (default: true). Set to false if the user asks to see the browser.",
                ],
                "timeout": [
                    "type": "integer",
                    "description": "Timeout in milliseconds (default: 30000).",
                ],
            ],
            "required": ["action"],
        ]
    }

    // MARK: - Execution

    func execute(args: [String: Any]) async throws -> ToolOutput {
        guard let action = args["action"] as? String else {
            throw BrowserToolError.missingParameter("action")
        }

        // Validate required parameters before connecting to the browser.
        try validateParams(action: action, args: args)

        let headless = args["headless"] as? Bool ?? true
        let timeoutMs = args["timeout"] as? Int ?? Self.defaultTimeoutMs

        logger.info("Browser action: \(action, privacy: .public)")

        let connection = try await BrowserManager.shared.ensureConnected(headless: headless)

        let text: String = switch action {
        case "navigate":
            try await navigate(args: args, connection: connection, timeoutMs: timeoutMs)
        case "click":
            try await click(args: args, connection: connection)
        case "type":
            try await typeText(args: args, connection: connection)
        case "get_text":
            try await getText(args: args, connection: connection)
        case "get_html":
            try await getHTML(args: args, connection: connection)
        case "screenshot":
            try await screenshot(connection: connection)
        case "evaluate":
            try await evaluate(args: args, connection: connection)
        case "wait":
            try await waitForSelector(args: args, connection: connection, timeoutMs: timeoutMs)
        default:
            throw BrowserToolError.missingParameter("action (unknown action: \(action))")
        }
        return ToolOutput(text: text)
    }

    // MARK: - Actions

    /// Navigate to a URL and wait for the page to load.
    private func navigate(args: [String: Any], connection: CDPConnection, timeoutMs: Int) async throws -> String {
        guard let url = args["url"] as? String else {
            throw BrowserToolError.missingParameter("url")
        }

        logger.info("Navigating to: \(url, privacy: .public)")

        // Start listening for Page.loadEventFired before navigating.
        guard let eventStream = connection.events else {
            throw BrowserToolError.navigationFailed("Browser event stream unavailable")
        }
        let loadTask = Task {
            for await event in eventStream where event.method == "Page.loadEventFired" {
                return
            }
        }

        let result = try await connection.send(method: "Page.navigate", params: ["url": url])

        // Check for navigation error.
        if let errorText = result["errorText"] as? String, !errorText.isEmpty {
            loadTask.cancel()
            throw BrowserToolError.navigationFailed(errorText)
        }

        // Wait for load event with timeout.
        let didLoad = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await loadTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if didLoad {
            logger.info("Navigation complete: \(url, privacy: .public)")
            return "Navigated to \(url)"
        } else {
            logger.warning("Navigation timed out after \(timeoutMs)ms: \(url, privacy: .public)")
            return "Navigated to \(url) (load event timed out after \(timeoutMs)ms, page may still be loading)"
        }
    }

    /// Click an element by CSS selector using JavaScript `element.click()`.
    private func click(args: [String: Any], connection: CDPConnection) async throws -> String {
        guard let selector = args["selector"] as? String else {
            throw BrowserToolError.missingParameter("selector")
        }

        let js = """
        (() => {
            const el = document.querySelector(\(jsStringLiteral(selector)));
            if (!el) return JSON.stringify({error: 'Element not found'});
            if (el.scrollIntoViewIfNeeded) { el.scrollIntoViewIfNeeded(); } else { el.scrollIntoView({block: 'center'}); }
            el.click();
            return JSON.stringify({success: true, tag: el.tagName, text: el.innerText?.substring(0, 100) || ''});
        })()
        """

        let result = try await evaluateJS(js, connection: connection)

        if let parsed = parseJSResult(result), parsed["error"] != nil {
            throw BrowserToolError.elementNotFound(selector)
        }

        logger.info("Clicked element: \(selector, privacy: .public)")
        return "Clicked element: \(selector)"
    }

    /// Type text into a focused or selected element.
    private func typeText(args: [String: Any], connection: CDPConnection) async throws -> String {
        guard let text = args["text"] as? String else {
            throw BrowserToolError.missingParameter("text")
        }

        // If a selector is provided, focus that element first.
        if let selector = args["selector"] as? String {
            let focusJS = """
            (() => {
                const el = document.querySelector(\(jsStringLiteral(selector)));
                if (!el) return JSON.stringify({error: 'Element not found'});
                el.focus();
                return JSON.stringify({success: true});
            })()
            """
            let focusResult = try await evaluateJS(focusJS, connection: connection)
            if let parsed = parseJSResult(focusResult), parsed["error"] != nil {
                throw BrowserToolError.elementNotFound(selector)
            }
        }

        // Insert the full text at once — more reliable for Unicode/CJK and faster than per-character dispatch.
        _ = try await connection.send(method: "Input.insertText", params: [
            "text": text,
        ])

        logger.info("Typed \(text.count) characters")
        return "Typed \(text.count) characters"
    }

    /// Extract text content from an element.
    private func getText(args: [String: Any], connection: CDPConnection) async throws -> String {
        let selector = args["selector"] as? String ?? "body"

        let js = """
        (() => {
            const el = document.querySelector(\(jsStringLiteral(selector)));
            if (!el) return JSON.stringify({error: 'Element not found'});
            return el.innerText || '';
        })()
        """

        let result = try await evaluateJS(js, connection: connection)

        if let parsed = parseJSResult(result), parsed["error"] != nil {
            throw BrowserToolError.elementNotFound(selector)
        }

        // Truncate very long text to avoid token bloat.
        let maxChars = 50000
        if result.count > maxChars {
            return String(result.prefix(maxChars)) + "\n[...truncated at \(maxChars) chars]"
        }

        return result
    }

    /// Get the full page HTML.
    private func getHTML(args: [String: Any], connection: CDPConnection) async throws -> String {
        let selector = args["selector"] as? String

        let js = if let selector {
            """
            (() => {
                const el = document.querySelector(\(jsStringLiteral(selector)));
                if (!el) return JSON.stringify({error: 'Element not found'});
                return el.outerHTML;
            })()
            """
        } else {
            "document.documentElement.outerHTML"
        }

        let result = try await evaluateJS(js, connection: connection)

        if let parsed = parseJSResult(result), parsed["error"] != nil {
            throw BrowserToolError.elementNotFound(selector ?? "html")
        }

        // Truncate very long HTML to avoid token bloat.
        let maxChars = 100_000
        if result.count > maxChars {
            return String(result.prefix(maxChars)) + "\n[...truncated at \(maxChars) chars]"
        }

        return result
    }

    /// Take a screenshot of the page and save it to ~/Documents/Tama/Screenshots/.
    private func screenshot(connection: CDPConnection) async throws -> String {
        // Set a reasonable viewport so screenshots aren't tiny (headless default is ~800x600).
        _ = try? await connection.send(method: "Emulation.setDeviceMetricsOverride", params: [
            "width": 1440,
            "height": 900,
            "deviceScaleFactor": 2,
            "mobile": false,
        ])

        // Brief pause for the page to re-layout at the new viewport size.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let result = try await connection.send(method: "Page.captureScreenshot", params: [
            "format": "png",
        ])

        guard let base64Data = result["data"] as? String,
              let imageData = Data(base64Encoded: base64Data)
        else {
            return "Screenshot captured but no data returned"
        }

        // Save to the Screenshots directory.
        let screenshotsDir = await PromptPanelController.screenshotsDirectory
        try? FileManager.default.createDirectory(
            atPath: screenshotsDir, withIntermediateDirectories: true
        )

        let timestamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        )
        let sanitized = timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let filename = "screenshot_\(sanitized).png"
        let filePath = (screenshotsDir as NSString).appendingPathComponent(filename)

        do {
            try imageData.write(to: URL(fileURLWithPath: filePath))
        } catch {
            logger.error("Failed to save screenshot: \(error.localizedDescription, privacy: .public)")
            return "Screenshot captured (\(imageData.count) bytes) but failed to save: \(error.localizedDescription)"
        }

        logger.info("Screenshot saved to \(filePath, privacy: .public)")

        // Get viewport dimensions for the response.
        let layoutResult = try? await connection.send(method: "Page.getLayoutMetrics", params: nil)
        let cssWidth = (layoutResult?["cssVisualViewport"] as? [String: Any])?["clientWidth"] as? Int ?? 0
        let cssHeight = (layoutResult?["cssVisualViewport"] as? [String: Any])?["clientHeight"] as? Int ?? 0

        var info = "Screenshot saved to \(filePath)"
        if cssWidth > 0, cssHeight > 0 {
            info += " (\(cssWidth)×\(cssHeight), \(imageData.count) bytes)"
        }
        info += "\n\nTo show the user, include it as a markdown image: ![screenshot](\(filePath))"
        return info
    }

    /// Execute arbitrary JavaScript in the page.
    private func evaluate(args: [String: Any], connection: CDPConnection) async throws -> String {
        guard let expression = args["text"] as? String else {
            throw BrowserToolError.missingParameter("text")
        }

        let result = try await evaluateJS(expression, connection: connection)
        return result
    }

    /// Wait for a CSS selector to appear in the DOM.
    private func waitForSelector(
        args: [String: Any],
        connection: CDPConnection,
        timeoutMs: Int
    ) async throws -> String {
        guard let selector = args["selector"] as? String else {
            throw BrowserToolError.missingParameter("selector")
        }

        let pollIntervalMs: UInt64 = 250
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while Date() < deadline {
            let js = "document.querySelector(\(jsStringLiteral(selector))) !== null"
            let result = try await evaluateJS(js, connection: connection)

            if result == "true" {
                logger.info("Element found: \(selector, privacy: .public)")
                return "Element found: \(selector)"
            }

            try await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }

        throw BrowserToolError.timeout("Waiting for selector: \(selector)")
    }

    // MARK: - Parameter Validation

    /// Validate required parameters for each action before connecting to the browser.
    /// This allows fast failure without incurring browser launch overhead.
    private func validateParams(action: String, args: [String: Any]) throws {
        switch action {
        case "navigate":
            guard args["url"] is String else {
                throw BrowserToolError.missingParameter("url")
            }
        case "click":
            guard args["selector"] is String else {
                throw BrowserToolError.missingParameter("selector")
            }
        case "type":
            guard args["text"] is String else {
                throw BrowserToolError.missingParameter("text")
            }
        case "evaluate":
            guard args["text"] is String else {
                throw BrowserToolError.missingParameter("text")
            }
        case "wait":
            guard args["selector"] is String else {
                throw BrowserToolError.missingParameter("selector")
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    /// Evaluate a JavaScript expression and return the string result.
    private func evaluateJS(_ expression: String, connection: CDPConnection) async throws -> String {
        let result = try await connection.send(method: "Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
        ])

        // Check for exceptions.
        if let exceptionDetails = result["exceptionDetails"] as? [String: Any] {
            let text = (exceptionDetails["text"] as? String)
                ?? (exceptionDetails["exception"] as? [String: Any])?["description"] as? String
                ?? "JavaScript exception"
            throw BrowserToolError.javaScriptError(text)
        }

        guard let resultObj = result["result"] as? [String: Any] else {
            return ""
        }

        // Return the value as a string.
        if let value = resultObj["value"] {
            if let stringValue = value as? String {
                return stringValue
            }
            // NSNumber bridges to both Bool and Int in Swift. Check CFBooleanRef
            // to distinguish actual JSON booleans from numbers.
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return number.boolValue ? "true" : "false"
                }
                return number.stringValue
            }
            // JSONSerialization requires a top-level array or dictionary — bare
            // numbers/strings crash. Guard with isValidJSONObject first.
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let jsonString = String(data: data, encoding: .utf8)
            {
                return jsonString
            }
            return "\(value)"
        }

        return resultObj["description"] as? String ?? ""
    }

    /// Escape a Swift string for use as a JavaScript string literal.
    private func jsStringLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    /// Try to parse a JSON string result from JavaScript.
    private func parseJSResult(_ result: String) -> [String: Any]? {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }
}

// MARK: - Errors

enum BrowserToolError: LocalizedError {
    case missingParameter(String)
    case elementNotFound(String)
    case navigationFailed(String)
    case javaScriptError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .missingParameter(name):
            "Missing required parameter: \(name)"
        case let .elementNotFound(selector):
            "Element not found for selector: \(selector)"
        case let .navigationFailed(reason):
            "Navigation failed: \(reason)"
        case let .javaScriptError(message):
            "JavaScript error: \(message)"
        case let .timeout(detail):
            "Timeout: \(detail)"
        }
    }
}
