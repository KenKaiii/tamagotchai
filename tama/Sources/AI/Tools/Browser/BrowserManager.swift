import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.browser"
)

/// Manages browser lifecycle — discovery, launch, and CDP connection.
///
/// Maintains a singleton `CDPConnection` that persists across tool calls within an agent loop.
final class BrowserManager: @unchecked Sendable {
    static let shared = BrowserManager()

    // MARK: - State

    private var connection: CDPConnection?
    private var browserProcess: Process?
    private var allLaunchedProcesses: [Process] = []
    private let lock = NSLock()

    private init() {}

    // MARK: - Known Chromium Browser Paths

    private static let knownBrowsers: [(name: String, path: String)] = [
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ("Brave Browser", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        ("Microsoft Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        ("Arc", "/Applications/Arc.app/Contents/MacOS/Arc"),
        ("Vivaldi", "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"),
        ("Opera", "/Applications/Opera.app/Contents/MacOS/Opera"),
        ("Chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium"),
    ]

    /// Returns the name of an installed system Chromium browser, or nil if none found.
    static var installedSystemBrowser: String? {
        knownBrowsers.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.name
    }

    // MARK: - Public API

    /// Returns an active CDP connection, creating one if needed.
    func ensureConnected(headless: Bool = false) async throws -> CDPConnection {
        // Return existing connection if still alive.
        if let existing = lock.withLock({ connection }), existing.isConnected {
            return existing
        }

        // Clear stale connection before reconnecting.
        lock.withLock {
            if let stale = connection, !stale.isConnected {
                logger.info("Clearing dead CDP connection, will reconnect")
                stale.disconnect()
                connection = nil
            }
        }

        // Try connect mode first (attach to already-running browser with debugging enabled).
        if let conn = await tryConnectMode() {
            lock.withLock { connection = conn }
            return conn
        }

        // Fall back to launch mode (start a new browser process).
        let conn = try await launchBrowser(headless: headless)
        lock.withLock { connection = conn }
        return conn
    }

    /// Disconnect from the browser and clean up.
    func disconnect() {
        lock.withLock {
            connection?.disconnect()
            connection = nil

            // Terminate all browser processes we ever launched
            let processesToKill = allLaunchedProcesses.filter(\.isRunning)
            for process in processesToKill {
                logger.info("Terminating browser process (PID \(process.processIdentifier))")
                process.terminate()
            }
            allLaunchedProcesses.removeAll()
            browserProcess = nil

            // Wait for processes to exit on a background thread to avoid blocking the caller.
            if !processesToKill.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    for process in processesToKill {
                        process.waitUntilExit()
                    }
                }
            }
        }
    }

    // MARK: - Connect Mode

    /// Try to attach to an already-running browser with remote debugging enabled.
    private func tryConnectMode() async -> CDPConnection? {
        // Try probing the default debug port.
        if let conn = await tryConnectToPort(9222) {
            return conn
        }

        // Try reading DevToolsActivePort from Chrome's user data directory.
        if let port = readDevToolsActivePort() {
            return await tryConnectToPort(port)
        }

        return nil
    }

    /// Attempt to connect to a debug port by fetching /json/list.
    private func tryConnectToPort(_ port: Int) async -> CDPConnection? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else { return nil }

            guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let target = targets.first(where: { ($0["type"] as? String) == "page" }),
                  let wsURLString = target["webSocketDebuggerUrl"] as? String,
                  let wsURL = URL(string: wsURLString)
            else { return nil }

            logger.info("Found running browser on port \(port), connecting via: \(wsURLString, privacy: .public)")

            let conn = CDPConnection()
            try await conn.connect(url: wsURL)
            return conn
        } catch {
            logger.debug("Could not connect to port \(port): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Read the DevToolsActivePort file from Chrome's default user data directory.
    private func readDevToolsActivePort() -> Int? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let portFilePaths = [
            "\(homeDir)/Library/Application Support/Google/Chrome/DevToolsActivePort",
            "\(homeDir)/Library/Application Support/BraveSoftware/Brave-Browser/DevToolsActivePort",
            "\(homeDir)/Library/Application Support/Microsoft Edge/DevToolsActivePort",
        ]

        for path in portFilePaths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                if let portString = lines.first, let port = Int(portString) {
                    logger.info("Found DevToolsActivePort at \(path, privacy: .public): port \(port)")
                    return port
                }
            }
        }

        return nil
    }

    // MARK: - Launch Mode

    /// Find and launch a Chromium browser with remote debugging enabled.
    private func launchBrowser(headless: Bool) async throws -> CDPConnection {
        // Prefer the downloaded Chrome for Testing if available.
        let downloadedPath = await ChromiumManager.shared.chromiumExecutablePath

        let browser: (name: String, path: String)
        if let downloadedPath {
            browser = ("Chrome for Testing", downloadedPath)
        } else if let found = Self.knownBrowsers.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            browser = found
        } else {
            let searched = Self.knownBrowsers.map(\.name).joined(separator: ", ")
            throw BrowserManagerError.noBrowserFound(searched)
        }

        logger.info("Launching \(browser.name, privacy: .public) in \(headless ? "headless" : "headed") mode")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: browser.path)

        var args = [
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-default-apps",
        ]

        // Use a separate user data dir to avoid profile lock conflicts with an already-running browser.
        let tempDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tama-browser-\(ProcessInfo.processInfo.processIdentifier)")
            .path
        args.append("--user-data-dir=\(tempDataDir)")

        if headless {
            args.append("--headless=new")
        }

        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw BrowserManagerError.launchFailed(error.localizedDescription)
        }

        lock.withLock {
            browserProcess = process
            allLaunchedProcesses.append(process)
        }

        // Parse stderr for the DevTools WebSocket URL (browser-level).
        let browserWSURL = try await parseWebSocketURL(from: stderrPipe, timeout: 15.0)

        // Extract the port from the browser WS URL to find a page target.
        guard let port = browserWSURL.port else {
            throw BrowserManagerError.launchFailed("Could not determine debug port from: \(browserWSURL)")
        }

        // Try to get a page-level target via /json/list. Headless mode may not have a page yet,
        // so we create one with /json/new if needed.
        let pageWSURL = try await discoverPageTarget(port: port)

        let conn = CDPConnection()
        try await conn.connect(url: pageWSURL)
        return conn
    }

    /// Discover a page target on the given debug port. Creates a new page if none exists.
    private func discoverPageTarget(port: Int) async throws -> URL {
        // Retry a few times — the browser may need a moment to create a default page.
        for attempt in 0 ..< 5 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            guard let listURL = URL(string: "http://127.0.0.1:\(port)/json/list") else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: listURL)
                if let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let page = targets.first(where: { ($0["type"] as? String) == "page" }),
                   let wsURLString = page["webSocketDebuggerUrl"] as? String,
                   let wsURL = URL(string: wsURLString)
                {
                    logger.info("Found page target: \(wsURLString, privacy: .public)")
                    return wsURL
                }
            } catch {
                logger.debug("Attempt \(attempt): /json/list failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // No page target found — try creating one.
        if let newURL = URL(string: "http://127.0.0.1:\(port)/json/new") {
            let (data, _) = try await URLSession.shared.data(from: newURL)
            if let target = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let wsURLString = target["webSocketDebuggerUrl"] as? String,
               let wsURL = URL(string: wsURLString)
            {
                logger.info("Created new page target: \(wsURLString, privacy: .public)")
                return wsURL
            }
        }

        throw BrowserManagerError.launchFailed("No page target found on port \(port)")
    }

    /// Read stderr from the launched browser to find the `DevTools listening on ws://...` line.
    private func parseWebSocketURL(from pipe: Pipe, timeout: TimeInterval) async throws -> URL {
        let handle = pipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            let resumeGuard = ContinuationGuard(continuation: continuation)

            // Set a timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeGuard.resume(throwing: BrowserManagerError.launchTimeout)
            }

            // Read stderr in a background thread.
            DispatchQueue.global().async {
                var buffer = ""
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }

                    guard let chunk = String(data: data, encoding: .utf8) else { continue }
                    buffer += chunk

                    // Look for the DevTools WebSocket URL line.
                    let lines = buffer.components(separatedBy: .newlines)
                    for line in lines {
                        guard line.contains("DevTools listening on ws://") else { continue }
                        guard let range = line.range(of: "ws://[^\\s]+", options: .regularExpression),
                              let url = URL(string: String(line[range]))
                        else { continue }
                        logger.info("Browser debug URL: \(url.absoluteString, privacy: .public)")
                        resumeGuard.resume(returning: url)
                        return
                    }
                }

                // Pipe closed without finding the URL.
                resumeGuard.resume(
                    throwing: BrowserManagerError.launchFailed(
                        "Browser exited without providing a debug URL"
                    )
                )
            }
        }
    }
}

// MARK: - Continuation Guard

/// Thread-safe one-shot continuation wrapper that satisfies `Sendable`.
private final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resume(throwing error: any Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Errors

enum BrowserManagerError: LocalizedError {
    case noBrowserFound(String)
    case launchFailed(String)
    case launchTimeout

    var errorDescription: String? {
        switch self {
        case let .noBrowserFound(searched):
            "No Chromium browser found. Searched for: \(searched)"
        case let .launchFailed(reason):
            "Failed to launch browser: \(reason)"
        case .launchTimeout:
            "Browser launch timed out — no debug URL received within timeout"
        }
    }
}
