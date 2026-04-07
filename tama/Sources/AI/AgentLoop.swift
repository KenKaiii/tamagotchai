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
struct AgentDismissError: Error {}

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
        maxTurns: Int = 50
    ) {
        registry = ToolRegistry.defaultRegistry(
            workingDirectory: workingDirectory
        )
        self.maxTurns = maxTurns
    }

    /// Run the agent loop with a conversation, streaming events back.
    func run(
        messages: [[String: Any]],
        systemPrompt: String? = nil,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> [[String: Any]] {
        var conversation = messages
        let tools = registry.apiToolDefinitions()
        var accumulatedText = ""

        for turn in 0 ..< maxTurns {
            try Task.checkCancellation()
            logger.info("Agent loop turn \(turn + 1)")

            let response: ClaudeResponse
            do {
                response = try await claude.sendWithTools(
                    messages: conversation,
                    tools: tools,
                    systemPrompt: systemPrompt,
                    onEvent: { event in
                        if case let .textDelta(text) = event {
                            // Stream text deltas immediately for smooth UI typing animation.
                            // Previously these were buffered until a tool call, which caused
                            // non-tool responses (especially voice) to appear all at once.
                            onEvent(.textDelta(text))
                        }
                        if case let .toolUseStart(id, name) = event {
                            if name != "dismiss" {
                                onEvent(.toolStart(name: name, id: id))
                            }
                        }
                    }
                )
            } catch {
                logger.error("sendWithTools failed on turn \(turn + 1): \(error.localizedDescription)")
                throw error
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
                logger.info("Turn complete — stop_reason=\(response.stopReason ?? "nil")")
                onEvent(.turnComplete(text: accumulatedText))
                return conversation
            }

            // If dismiss tool is in the calls, throw to immediately stop the loop
            if toolCalls.contains(where: { $0.name == "dismiss" }) {
                logger.info("Dismiss tool detected — ending agent loop")
                throw AgentDismissError()
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

        for call in toolCalls {
            let output: String
            nonisolated(unsafe) let args = call.input

            // Emit toolRunning with string-coerced args for the UI indicator.
            let stringArgs = args.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = "\(pair.value)"
            }
            onEvent(.toolRunning(name: call.name, args: stringArgs))

            if let tool = registry.tool(named: call.name) {
                let startTime = CFAbsoluteTimeGetCurrent()
                logger.info("Tool execution start: \(call.name) (args: \(Array(call.input.keys)))")
                do {
                    output = try await tool.execute(args: args)
                    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    logger.info("Tool execution complete: \(call.name) — \(output.count) chars, \(durationMs)ms")
                } catch {
                    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    logger
                        .error("Tool execution failed: \(call.name) — \(error.localizedDescription) (\(durationMs)ms)")
                    output = "Error: \(error.localizedDescription)"
                }
            } else {
                logger.warning("Unknown tool requested: \(call.name)")
                output = "Error: Unknown tool '\(call.name)'"
            }

            let truncated = truncateOutput(output)
            onEvent(
                .toolResult(name: call.name, output: truncated)
            )

            results.append([
                "type": "tool_result",
                "tool_use_id": call.id,
                "content": truncated,
            ])
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
