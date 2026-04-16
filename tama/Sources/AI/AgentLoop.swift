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

/// Matches a sentence/clause boundary followed by whitespace OR end of string.
/// Used to anchor visual-tool barriers to the boundary BEFORE the tool's
/// introducing phrase, so cursors appear as that phrase starts being spoken
/// instead of after the model finishes describing the target.
///
/// Includes colons because models frequently use label syntax in
/// walkthroughs ("Apple menu:", "Brave browser:") — those are functionally
/// sentence-like separators. Without colons, multi-item responses stall all
/// barriers at the last period and cursors fire at round-trip speed instead
/// of at narration cadence. Matches TTS's own clause-boundary pattern.
// swiftlint:disable:next force_try
private let sentenceBoundaryPattern = try! NSRegularExpression(
    pattern: "[.!?:](?=\\s|$)",
    options: []
)

/// Runs the tool execution loop: send → tool_use → execute → tool_result → repeat.
@MainActor
final class AgentLoop {
    /// Tools that visually annotate the screen while the agent speaks. Each
    /// one must fire at the moment its matching narration reaches the user's
    /// ears — not when the LLM emits the tool_use block (which happens in
    /// milliseconds). Gated on `SpeechService.awaitSpokenChars` during voice
    /// calls; no-op outside of them.
    static let voiceSyncToolNames: Set<String> = [
        "point",
        "highlight",
        "arrow",
        "emphasize",
        "countdown",
        "scroll_hint",
        "show_shortcut",
    ]

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
    func run(
        messages: [[String: Any]],
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> [[String: Any]] {
        var conversation = messages
        let tools = registry.apiToolDefinitions()
        var accumulatedText = ""

        // Per-run state for voice/visual sync. `cumulativeInputChars` mirrors
        // the chars fed into `SpeechService.feedChunk` (same source — text
        // deltas). `lastSentenceBoundaryChars` tracks the cumulative-char
        // position of the most recent sentence-ending punctuation. When a
        // tool_use block starts, we snapshot the sentence boundary as the
        // tool's barrier (NOT the tool's exact stream position) — so the
        // visual fires when the sentence INTRODUCING it starts being spoken,
        // not after the model finishes describing it. Models tend to emit
        // tool_use at the END of a description paragraph; without this
        // anchoring, cursors appear after the explanation has already played.
        // State persists across turns within a single run.
        nonisolated(unsafe) var cumulativeInputChars = 0
        nonisolated(unsafe) var lastSentenceBoundaryChars = 0
        nonisolated(unsafe) var toolBarriers: [String: Int] = [:]

        for turn in 0 ..< maxTurns {
            try Task.checkCancellation()
            logger.info("▶︎ Agent loop turn \(turn + 1) — \(conversation.count) msgs")

            let requestStart = CFAbsoluteTimeGetCurrent()
            nonisolated(unsafe) var firstDeltaAt: CFAbsoluteTime?
            nonisolated(unsafe) var deltaCount = 0
            let response: ClaudeResponse
            do {
                response = try await claude.sendWithTools(
                    messages: conversation,
                    tools: tools,
                    systemPrompt: systemPrompt,
                    maxTokens: maxTokens,
                    onEvent: { event in
                        if case let .textDelta(text) = event {
                            // Stream text deltas immediately for smooth UI typing animation.
                            // Previously these were buffered until a tool call, which caused
                            // non-tool responses (especially voice) to appear all at once.
                            if firstDeltaAt == nil {
                                firstDeltaAt = CFAbsoluteTimeGetCurrent()
                            }
                            deltaCount += 1
                            let deltaStartPos = cumulativeInputChars
                            cumulativeInputChars += text.count
                            // Scan this delta for sentence-ending punctuation
                            // and record the latest boundary position. Used
                            // below when a tool_use fires — barrier is set to
                            // the LAST sentence boundary, not the tool's
                            // exact stream position, so cursors appear at the
                            // start of the introducing sentence.
                            let nsText = text as NSString
                            let range = NSRange(location: 0, length: nsText.length)
                            for match in sentenceBoundaryPattern.matches(in: text, range: range) {
                                let boundaryEnd = deltaStartPos + match.range.location + match.range.length
                                if boundaryEnd > lastSentenceBoundaryChars {
                                    lastSentenceBoundaryChars = boundaryEnd
                                }
                            }
                            onEvent(.textDelta(text))
                        }
                        if case let .toolUseStart(id, name) = event {
                            // Anchor the barrier to the last sentence
                            // boundary BEFORE this tool — cursor fires as the
                            // introducing sentence begins, not after the
                            // model finishes describing the target. See the
                            // detailed comment above the state declarations.
                            toolBarriers[id] = lastSentenceBoundaryChars
                            if name != "dismiss" {
                                onEvent(.toolStart(name: name, id: id))
                            }
                        }
                    }
                )
            } catch {
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - requestStart) * 1000)
                logger
                    .error(
                        "✗ sendWithTools failed on turn \(turn + 1) after \(elapsed)ms: \(error.localizedDescription, privacy: .public)"
                    )
                throw error
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
                barriers: toolBarriers,
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

    /// Extracts the user-visible label for a visual tool from its args.
    /// All visual tools use `label`; fall back to the tool name as a last
    /// resort so we still match *something* in narration for word-level sync.
    private static func labelForVisualTool(args: [String: Any], fallback: String) -> String {
        if let label = args["label"] as? String, !label.isEmpty { return label }
        return fallback
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
        barriers: [String: Int],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        let modelSupportsVision = claude.currentModel.supportsVision

        for call in toolCalls {
            let toolOutput: ToolOutput
            nonisolated(unsafe) let args = call.input

            // Coerce args once — used both after the barrier awaits below and
            // potentially in pre-wait logging.
            let stringArgs = args.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = "\(pair.value)"
            }

            // Word-level voice/visual sync: visual tools (point, highlight,
            // arrow, etc.) register with `SpeechService.registerPendingVisual`
            // using their `label` / `description` arg. When Kokoro's per-word
            // timings surface that word in subsequent narration, the actual
            // cursor fires at the EXACT moment the word is uttered.
            //
            // This decouples cursor timing from the model's tool_use stream
            // position — so whether Claude narrates-then-batches-tools or
            // batches-tools-then-narrates (it does both), cursors land when
            // the user actually hears the word. If the label never appears
            // in narration, a safety net in `completeStream` fires all
            // unmatched visuals at end-of-stream.
            //
            // The agent loop returns a synthetic tool_result immediately
            // so the model can keep streaming without blocking on playback.
            if Self.voiceSyncToolNames.contains(call.name),
               await SpeechService.shared.isSpeaking || SpeechService.shared.spokenCharsSnapshot > 0,
               let tool = registry.tool(named: call.name)
            {
                let label = Self.labelForVisualTool(args: args, fallback: call.name)
                let toolName = call.name
                let toolId = call.id
                let argsCapture = args
                logger.info("Voice sync: registering \(toolName) for word '\(label)'")
                SpeechService.shared.registerPendingVisual(id: toolId, label: label) {
                    Task { @MainActor in
                        let startTime = CFAbsoluteTimeGetCurrent()
                        do {
                            let output = try await tool.execute(args: argsCapture)
                            let ms = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                            let logger = Logger(subsystem: "com.unstablemind.tama", category: "agent")
                            logger
                                .info(
                                    "Voice sync fired: \(toolName) — \(output.text.count) chars, \(ms)ms"
                                )
                        } catch {
                            let logger = Logger(subsystem: "com.unstablemind.tama", category: "agent")
                            logger.error("Voice sync fire failed: \(toolName) — \(error.localizedDescription)")
                        }
                    }
                }
                onEvent(.toolRunning(name: call.name, args: stringArgs))
                let synthetic = "Visual '\(label)' queued — cursor fires when you say the word."
                onEvent(.toolResult(name: call.name, output: synthetic))
                results.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": synthetic,
                ])
                continue
            }

            // Non-voice-sync path (panel mode, non-visual tools, or visual
            // tools outside a call): execute immediately and report result.
            // Barriers still supported for anyone awaiting `awaitSpokenChars`.
            if Self.voiceSyncToolNames.contains(call.name),
               let barrier = barriers[call.id]
            {
                let waitStart = CFAbsoluteTimeGetCurrent()
                logger.info("Voice sync fallback: \(call.name) awaiting TTS barrier \(barrier)")
                await SpeechService.shared.awaitSpokenChars(barrier)
                let waitedMs = Int((CFAbsoluteTimeGetCurrent() - waitStart) * 1000)
                logger.info("Voice sync fallback: \(call.name) barrier \(barrier) met after \(waitedMs)ms")
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
