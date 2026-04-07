import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "tool.browser"
)

/// A CDP event pushed by the browser (no `id` field).
struct CDPEvent: @unchecked Sendable {
    let method: String
    let params: [String: Any]
}

/// Low-level Chrome DevTools Protocol WebSocket client.
///
/// Sends JSON-RPC commands (`{id, method, params}`) and matches responses by `id`.
/// Browser-pushed events are forwarded through an `AsyncStream`.
final class CDPConnection: @unchecked Sendable {
    // MARK: - State

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var nextCommandID = 1
    private var pendingCommands: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?

    /// Whether the underlying WebSocket is still connected.
    private(set) var isConnected = false

    private var eventContinuation: AsyncStream<CDPEvent>.Continuation?

    /// Stream of CDP events (e.g. `Page.loadEventFired`).
    private(set) var events: AsyncStream<CDPEvent>?

    // MARK: - Lifecycle

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        events = AsyncStream<CDPEvent> { continuation in
            self.eventContinuation = continuation
        }
    }

    /// Connect to a CDP WebSocket endpoint.
    func connect(url: URL) async throws {
        logger.info("Connecting to CDP endpoint: \(url.absoluteString, privacy: .public)")
        let task = session.webSocketTask(with: url)
        // CDP can send very large messages (e.g. base64 screenshots).
        // The default 1 MB limit causes "Message too long" errors.
        task.maximumMessageSize = 64 * 1024 * 1024 // 64 MB
        task.resume()
        webSocketTask = task
        isConnected = true

        // Start the background receive loop.
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Enable the CDP domains we need.
        _ = try await send(method: "Page.enable", params: nil)
        _ = try await send(method: "Runtime.enable", params: nil)
        logger.info("CDP connection established")
    }

    /// Send a CDP command and wait for its response.
    func send(method: String, params: [String: Any]?) async throws -> [String: Any] {
        guard let ws = webSocketTask else {
            throw CDPError.notConnected
        }

        let commandID: Int = lock.withLock {
            let id = nextCommandID
            nextCommandID += 1
            return id
        }

        var message: [String: Any] = [
            "id": commandID,
            "method": method,
        ]
        if let params {
            message["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        let jsonString = String(data: data, encoding: .utf8)!

        logger.debug("CDP send [id=\(commandID)] \(method)")

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pendingCommands[commandID] = continuation
            }

            ws.send(.string(jsonString)) { [weak self] error in
                if let error {
                    logger.error("CDP send error [id=\(commandID)]: \(error.localizedDescription, privacy: .public)")
                    guard let self else { return }
                    let cont: CheckedContinuation<[String: Any], any Error>? = lock.withLock {
                        self.pendingCommands.removeValue(forKey: commandID)
                    }
                    cont?.resume(throwing: error)
                }
            }
        }
    }

    /// Disconnect from the browser.
    func disconnect() {
        logger.info("Disconnecting CDP connection")
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()

        // Fail any pending commands.
        lock.withLock {
            for (_, continuation) in pendingCommands {
                continuation.resume(throwing: CDPError.disconnected)
            }
            pendingCommands.removeAll()
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case let .string(text):
                    handleMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("CDP receive error: \(error.localizedDescription, privacy: .public)")
                }
                isConnected = false
                // Fail any pending commands so callers don't hang.
                lock.withLock {
                    for (_, continuation) in pendingCommands {
                        continuation.resume(throwing: CDPError.disconnected)
                    }
                    pendingCommands.removeAll()
                }
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.warning("CDP received non-JSON message")
            return
        }

        // Response to a command (has `id` field).
        if let id = json["id"] as? Int {
            let continuation: CheckedContinuation<[String: Any], any Error>? = lock.withLock {
                pendingCommands.removeValue(forKey: id)
            }

            if let errorInfo = json["error"] as? [String: Any] {
                let message = errorInfo["message"] as? String ?? "Unknown CDP error"
                logger.error("CDP error [id=\(id)]: \(message, privacy: .public)")
                continuation?.resume(throwing: CDPError.commandFailed(message))
            } else {
                let result = json["result"] as? [String: Any] ?? [:]
                continuation?.resume(returning: result)
            }
            return
        }

        // Event (has `method` field, no `id`).
        if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]
            eventContinuation?.yield(CDPEvent(method: method, params: params))
        }
    }
}

// MARK: - Errors

enum CDPError: LocalizedError {
    case notConnected
    case disconnected
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a browser"
        case .disconnected:
            "Connection was closed"
        case let .commandFailed(message):
            "CDP command failed: \(message)"
        }
    }
}
