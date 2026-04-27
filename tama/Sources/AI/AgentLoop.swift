import Foundation
import os

/// Event emitted by the agent loop for UI updates.
enum AgentEvent: Sendable {
    case textDelta(String)
    case toolStart(name: String, id: String)
    case toolRunning(name: String, args: [String: String])
    case toolResult(name: String, output: String)
    case turnComplete(text: String)
    case error(String)
}

/// Thrown when the agent invokes the dismiss tool to close the panel.
/// Carries the conversation so the caller can save it before dismissing.
struct AgentDismissError: Error {
    let conversation: [[String: Any]]
}

/// Thrown when the agent loop is interrupted mid-run by an error (typically a
/// transient network failure). Carries the conversation up to the last good
/// state so the caller can persist partial progress before surfacing the error
/// — otherwise the next user prompt would resume with no memory of the work
/// already done.
struct AgentInterruptedError: Error {
    let conversation: [[String: Any]]
    let underlying: Error

    var localizedDescription: String { underlying.localizedDescription }
}

/// Runs the tool execution loop: send → tool_use → execute → tool_result → repeat.
@MainActor
final class AgentLoop {
    private let claude = ClaudeService.shared
    private let registry: ToolRegistry
    private let maxTurns: Int
    private let logger = Logger(
        subsystem: "com.unstablemind.tama",
        category: "agent"
    )

    init(
        workingDirectory: String? = nil,
        registry: ToolRegistry? = nil,
        maxTurns: Int = 50
    ) {
        self.registry = registry ?? ToolRegistry.defaultRegistry(
            workingDirectory: workingDirectory
        )
        self.maxTurns = maxTurns
    }

    /// Run the agent loop with a conversation, streaming events back.
    ///
    /// `useBasePrompt` controls whether the global `baseSystemPrompt` is
    /// prepended. Default `true` for the chat panel. The voice call agent
    /// passes `false` so its self-contained call prompt isn't diluted by
    /// the chat-shaped base prompt (and its "I did X — want Y too?" pattern
    /// that conflicts with the chat-shaped prompt's follow-up rule).
    func run(
        messages: [[String: Any]],
        systemPrompt: String? = nil,
        useBasePrompt: Bool = true,
        maxTokens: Int? = nil,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> [[String: Any]] {
        var conversation = messages
        let tools = registry.apiToolDefinitions()
        var accumulatedText = ""

        for turn in 0 ..< maxTurns {
            try Task.checkCancellation()
            logger.info("▶︎ Agent loop turn \(turn + 1) — \(conversation.count) msgs")

            let requestStart = CFAbsoluteTimeGetCurrent()
            nonisolated(unsafe) var firstDeltaAt: CFAbsoluteTime?
            nonisolated(unsafe) var deltaCount = 0
            let sendEvent: @Sendable (StreamEvent) -> Void = { event in
                if case let .textDelta(text) = event {
                    if firstDeltaAt == nil {
                        firstDeltaAt = CFAbsoluteTimeGetCurrent()
                    }
                    deltaCount += 1
                    onEvent(.textDelta(text))
                }
                if case let .toolUseStart(id, name) = event {
                    if name != "dismiss" {
                        onEvent(.toolStart(name: name, id: id))
                    }
                }
            }

            let response: ClaudeResponse
            do {
                response = try await claude.sendWithTools(
                    messages: conversation,
                    tools: tools,
                    systemPrompt: systemPrompt,
                    useBasePrompt: useBasePrompt,
                    maxTokens: maxTokens,
                    onEvent: sendEvent
                )
            } catch {
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - requestStart) * 1000)
                // Retry once for transient network errors. The underlying
                // URLSession stream sometimes drops on long agent runs;
                // a single retry recovers most cases without surfacing an
                // error to the user or losing partial progress.
                if Self.isTransientNetworkError(error), !Task.isCancelled {
                    logger
                        .warning(
                            "⚠️ Turn \(turn + 1) transient failure after \(elapsed)ms, retrying: \(error.localizedDescription, privacy: .public)"
                        )
                    try? await Task.sleep(for: .milliseconds(500))
                    do {
                        response = try await claude.sendWithTools(
                            messages: conversation,
                            tools: tools,
                            systemPrompt: systemPrompt,
                            useBasePrompt: useBasePrompt,
                            maxTokens: maxTokens,
                            onEvent: sendEvent
                        )
                    } catch {
                        let retryElapsed = Int((CFAbsoluteTimeGetCurrent() - requestStart) * 1000)
                        logger
                            .error(
                                "✗ sendWithTools retry failed on turn \(turn + 1) after \(retryElapsed)ms: \(error.localizedDescription, privacy: .public)"
                            )
                        throw AgentInterruptedError(conversation: conversation, underlying: error)
                    }
                } else {
                    logger
                        .error(
                            "✗ sendWithTools failed on turn \(turn + 1) after \(elapsed)ms: \(error.localizedDescription, privacy: .public)"
                        )
                    throw AgentInterruptedError(conversation: conversation, underlying: error)
                }
            }

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - requestStart) * 1000)
            if let ttfb = firstDeltaAt {
                let ttfbMs = Int((ttfb - requestStart) * 1000)
                logger
                    .info(
                        "✅ Turn \(turn + 1) done — TTFB \(ttfbMs)ms, total \(totalMs)ms, \(deltaCount) deltas, stop=\(response.stopReason ?? "nil")"
                    )
            } else {
                logger
                    .info(
                        "✅ Turn \(turn + 1) done — no text deltas, total \(totalMs)ms, stop=\(response.stopReason ?? "nil")"
                    )
            }

            // Build the assistant message content for conversation
            let assistantContent = buildAssistantContent(
                from: response
            )
            var assistantMessage: [String: Any] = [
                "role": "assistant",
                "content": assistantContent,
            ]
            // Preserve reasoning_content for OpenAI-compatible providers (Moonshot)
            // that require it in the round-trip when thinking is enabled.
            if let reasoning = response.reasoningContent {
                assistantMessage["reasoning_content"] = reasoning
            }
            conversation.append(assistantMessage)

            // Accumulate text
            accumulatedText += response.textContent

            // Continue only if stop_reason is "tool_use" and we have tool calls
            let toolCalls = response.toolUseCalls
            let shouldContinue =
                response.stopReason == "tool_use" && !toolCalls.isEmpty
            if !shouldContinue {
                onEvent(.turnComplete(text: accumulatedText))
                return conversation
            }

            // If dismiss tool is in the calls, throw to immediately stop the loop
            if toolCalls.contains(where: { $0.name == "dismiss" }) {
                logger.info("Dismiss tool detected — ending agent loop")
                throw AgentDismissError(conversation: conversation)
            }

            // If end_call tool is in the calls, throw to end the voice call
            if toolCalls.contains(where: { $0.name == "end_call" }) {
                logger.info("End call tool detected — ending agent loop")
                throw AgentEndCallError(conversation: conversation)
            }

            // Execute each tool and collect results
            try Task.checkCancellation()
            let toolResults = await executeTools(
                toolCalls,
                onEvent: onEvent
            )

            // Add tool results as user message
            conversation.append([
                "role": "user",
                "content": toolResults,
            ])
        }

        let limit = maxTurns
        logger.warning("Agent loop hit max turns (\(limit))")
        onEvent(
            .error("Reached maximum number of turns (\(limit))")
        )
        onEvent(.turnComplete(text: accumulatedText))
        return conversation
    }

    // MARK: - Private Helpers

    /// Returns true for URLSession errors that commonly resolve on retry.
    private static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .dataNotAllowed,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private func buildAssistantContent(
        from response: ClaudeResponse
    ) -> [[String: Any]] {
        response.content.map { block in
            switch block {
            case let .text(text):
                ["type": "text", "text": text]
            case let .toolUse(id, name, input):
                [
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input,
                ] as [String: Any]
            }
        }
    }

    private func executeTools(
        _ toolCalls: [(id: String, name: String, input: [String: Any])],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        let modelSupportsVision = claude.currentModel.supportsVision

        for call in toolCalls {
            let toolOutput: ToolOutput
            nonisolated(unsafe) let args = call.input

            let stringArgs = args.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = "\(pair.value)"
            }

            onEvent(.toolRunning(name: call.name, args: stringArgs))

            if let tool = registry.tool(named: call.name) {
                let startTime = CFAbsoluteTimeGetCurrent()
                logger.info("Tool execution start: \(call.name) (args: \(Array(call.input.keys)))")
                do {
                    toolOutput = try await tool.execute(args: args)
                    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    let imgCount = toolOutput.images.count
                    logger
                        .info(
                            "Tool execution complete: \(call.name) — \(toolOutput.text.count) chars, \(imgCount) images, \(durationMs)ms"
                        )
                } catch {
                    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    logger
                        .error("Tool execution failed: \(call.name) — \(error.localizedDescription) (\(durationMs)ms)")
                    toolOutput = ToolOutput(text: "Error: \(error.localizedDescription)")
                }
            } else {
                logger.warning("Unknown tool requested: \(call.name)")
                toolOutput = ToolOutput(text: "Error: Unknown tool '\(call.name)'")
            }

            let truncated = truncateOutput(toolOutput.text)
            onEvent(
                .toolResult(name: call.name, output: truncated)
            )

            // If the tool produced images and the active model supports vision,
            // emit a tool_result with array content carrying both text and image
            // blocks. Otherwise discard images and emit text-only.
            if !toolOutput.images.isEmpty, modelSupportsVision {
                var content: [[String: Any]] = [["type": "text", "text": truncated]]
                for img in toolOutput.images {
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": img.mediaType,
                            "data": img.data.base64EncodedString(),
                        ] as [String: Any],
                    ])
                }
                results.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": content,
                ])
            } else {
                if !toolOutput.images.isEmpty {
                    logger
                        .info(
                            "Discarding \(toolOutput.images.count) image(s) from '\(call.name)' — model does not support vision"
                        )
                }
                results.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": truncated,
                ])
            }
        }

        return results
    }

    private func truncateOutput(
        _ output: String,
        maxChars: Int = 100_000
    ) -> String {
        if output.count <= maxChars {
            return output
        }
        let prefix = output.prefix(maxChars)
        return String(prefix) + "\n[...truncated at \(maxChars) chars]"
    }
}
