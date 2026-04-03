import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tamagotchai",
    category: "tool.bash"
)

/// Agent tool that executes shell commands via `/bin/bash -c`.
final class BashTool: AgentTool {
    let name = "bash"
    let description = "Execute a bash command. Returns exit code and combined stdout/stderr."

    let workingDirectory: String

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Input Schema

    nonisolated var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "The bash command to execute.",
                ],
                "timeout": [
                    "type": "integer",
                    "description":
                        "Timeout in milliseconds (default: 120000).",
                ],
            ],
            "required": ["command"],
        ]
    }

    // MARK: - Execution

    private static let maxTotalLines = 2000
    private static let keepHeadLines = 200
    private static let keepTailLines = 200
    private static let defaultTimeoutMs = 120_000
    /// Maximum output size in bytes (10 MB).
    private static let maxOutputBytes = 10 * 1024 * 1024

    func execute(args: [String: Any]) async throws -> String {
        guard let command = args["command"] as? String else {
            throw BashToolError.missingCommand
        }

        let timeoutMs = args["timeout"] as? Int ?? Self.defaultTimeoutMs
        logger.info("Executing bash command: \(command.prefix(200), privacy: .public), timeout: \(timeoutMs)ms")
        let (process, pipe) = try makeProcess(command: command)

        let readHandle = pipe.fileHandleForReading
        let readTask = Task.detached { () -> Data in
            Self.readIncrementally(from: readHandle, limit: Self.maxOutputBytes)
        }

        let didTimeout = await waitWithTimeout(
            process: process,
            pipe: pipe,
            seconds: Double(timeoutMs) / 1000.0
        )

        // Give the read task a short deadline (5s) after the process exits
        // so child processes holding the pipe don't block us forever.
        let outputData: Data = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await readTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            for await value in group {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            return await readTask.value
        }

        let exitCode = process.terminationStatus
        let rawOutput = String(data: outputData, encoding: .utf8) ?? ""
        logger
            .info(
                "Bash command complete: exitCode=\(exitCode), outputLength=\(rawOutput.count), timedOut=\(didTimeout)"
            )

        return formatResult(
            exitCode: exitCode,
            output: truncate(rawOutput),
            didTimeout: didTimeout,
            timeoutMs: timeoutMs
        )
    }

    // MARK: - Helpers

    /// Reads from a file handle incrementally up to `limit` bytes.
    private static func readIncrementally(from handle: FileHandle, limit: Int) -> Data {
        var result = Data()
        let chunkSize = 65536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            result.append(chunk)
            if result.count >= limit {
                result = result.prefix(limit)
                break
            }
        }
        return result
    }

    /// Creates and starts a `Process` for the given shell command.
    /// Launches in a new process group so the entire tree can be killed on timeout.
    private func makeProcess(command: String) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["TERM": "dumb"]
        ) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            logger.error("Process launch failed: \(error.localizedDescription, privacy: .public)")
            throw BashToolError.launchFailed(error.localizedDescription)
        }
        return (process, pipe)
    }

    /// Shell-escape a string for embedding in a bash -c argument.
    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Waits for the process to exit, terminating it if the timeout is exceeded.
    /// Closes the pipe on timeout so the read task can complete.
    /// Returns `true` if the process timed out.
    private func waitWithTimeout(process: Process, pipe: Pipe, seconds: Double) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let group = DispatchGroup()
            group.enter()

            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }

            if group.wait(timeout: .now() + seconds) == .timedOut {
                // Kill the process group so child processes don't hold the pipe open.
                let pid = process.processIdentifier
                kill(-pid, SIGTERM)

                // Allow graceful shutdown, then force kill.
                if group.wait(timeout: .now() + 2) == .timedOut {
                    kill(-pid, SIGKILL)
                    process.terminate()
                }

                // Close the pipe so the read task returns.
                try? pipe.fileHandleForReading.close()

                continuation.resume(returning: true)
            } else {
                continuation.resume(returning: false)
            }
        }
    }

    /// Formats the final result string from exit code and output.
    private func formatResult(
        exitCode: Int32,
        output: String,
        didTimeout: Bool,
        timeoutMs: Int
    ) -> String {
        var text = output
        if didTimeout {
            text += "\n[Process timed out after \(timeoutMs)ms]"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Exit code: \(exitCode)"
        }
        return "Exit code: \(exitCode)\n\(text)"
    }

    // MARK: - Truncation

    /// If the output exceeds `maxTotalLines`, keep the first and last N lines
    /// with a truncation notice in between.
    private func truncate(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > Self.maxTotalLines else {
            return text
        }
        let head = lines.prefix(Self.keepHeadLines)
        let tail = lines.suffix(Self.keepTailLines)
        let dropped = lines.count - Self.keepHeadLines - Self.keepTailLines
        return (Array(head) + ["[...truncated \(dropped) lines...]"] + Array(tail))
            .joined(separator: "\n")
    }
}

// MARK: - Errors

enum BashToolError: LocalizedError {
    case missingCommand
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            "Missing required parameter: command"
        case let .launchFailed(reason):
            "Failed to launch process: \(reason)"
        }
    }
}
