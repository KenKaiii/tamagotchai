# Vision / Image Input Across Providers

Give the agent the ability to **see** images. A new `screenshot` tool captures the user's screen, saves it to `~/Documents/Tama/Screenshots/`, and the image is shipped to the selected LLM in the provider's native vision format. Only providers whose models support vision get the image; text-only models get a text description of the file path.

---

## 1. Provider vision support (audit)

| Model (id) | Provider | Endpoint type | Vision? | Transport |
|---|---|---|---|---|
| `kimi-k2.5` | Moonshot | OpenAI chat completions | ✅ yes — "native multimodal" per Moonshot docs | `{type:"image_url", image_url:{url:"data:image/png;base64,..."}}` — **base64 data URL only, no http URLs** |
| `xiaomi-token-plan-sgp/mimo-v2-pro` | Xiaomi Token Plan | OpenAI chat completions | ❌ no — Token Plan catalog has no vision model; MiMo-VL-7B is a separate open-source release not exposed via Token Plan API | n/a |
| `gpt-5.4`, `gpt-5.4-mini` | OpenAI ChatGPT Codex (`/responses`) | Responses API | ✅ yes | `{type:"input_image", image_url:"data:image/png;base64,..."}` |
| `gpt-5.3-codex` | OpenAI | Responses API | ✅ yes — OpenAI Codex docs explicitly list "image inputs" |`{type:"input_image", ...}` |
| `codex-mini-latest` | OpenAI | Responses API | ⚠️ text-only legacy — treat as no, verify during testing | n/a |
| `MiniMax-M2.7` / `MiniMax-M2.7-highspeed` | MiniMax | Anthropic Messages (`/anthropic/v1/messages`) | ❌ the `/anthropic` endpoint **silently drops image content blocks** per upstream GitHub issue #92 — vision is pay-per-use on a separate MiniMax-VL endpoint not exposed by the Coding Plan key | n/a |

Default: new `supportsVision: Bool` on `ModelInfo` defaults to `false`; plan marks each entry explicitly. User sees a toast/log when they ask for a screenshot while a non-vision model is selected.

---

## 2. How each provider "sees" an image (wire formats)

Internal canonical form (kept verbatim in `conversation` arrays between turns):

```json
{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "<b64>"}}
```

This is the Anthropic Messages block format. Request builders translate it at send time:

- **MiniMax `/anthropic`** → pass through unchanged (format is already Anthropic-native). Even though real vision will likely fail, we don't mangle the payload — the user gets back the API's own "image not supported" response, which is better than silently dropping content.
- **Codex `/responses`** (OpenAI) → convert to `{type:"input_image", image_url:"data:<mt>;base64,<b64>"}` inside the user's `content` array. `CodexRequestBuilder.convertMessages` already walks user blocks — extend the block switch to emit `input_image`.
- **OpenAI chat completions (Moonshot/Xiaomi)** → convert to `{type:"image_url", image_url:{url:"data:<mt>;base64,<b64>"}}`. `ClaudeService.convertMessageToOpenAI` already handles user arrays — extend it.

Assistant messages never contain image blocks (only text/tool_use), so we don't need output-side conversion.

---

## 3. Where images live on disk

Already done — `~/Documents/Tama/Screenshots/` is created by `PromptPanelController.ensureWorkspace()` at startup and exposed via `PromptPanelController.screenshotsDirectory`. The `BrowserTool.screenshot()` action writes there today (`Tama/Sources/AI/Tools/Browser/BrowserTool.swift:291-305`). The new `ScreenshotTool` will reuse this path — same filename convention (`screenshot_<ISO8601>.png`).

---

## 4. Standalone `screenshot` tool

New file `Tama/Sources/AI/Tools/ScreenshotTool.swift` — AgentTool that captures the main display (full-screen) using `ScreenCaptureKit` (Apple's blessed API since macOS 14; required on macOS 15+ since `CGWindowListCreateImage` is deprecated).

### API
```
name: "screenshot"
description: "Capture a screenshot of the user's screen and attach it for analysis. The image is saved to ~/Documents/Tama/Screenshots/ and sent to the model so you can visually see what's on the screen. Use this when the user asks about what they're looking at, to diagnose UI issues, read text from windows, or verify visual state."
properties:
  display: integer (optional, 0-based index; default = main display)
  format:  "png" | "jpeg"  (default "jpeg" — dramatically smaller base64 payloads)
  quality: integer 1-100   (default 85, jpeg only)
```

### Implementation
- Use `SCShareableContent.current` to enumerate displays, pick by index (default = `content.displays.first`).
- Build `SCContentFilter(display: display, excludingWindows: [])`.
- `SCStreamConfiguration` with `width/height = display.width/height * scale` (retina aware), `showsCursor = false`, `captureResolution = .best`.
- `SCScreenshotManager.captureImage(contentFilter:configuration:)` → `CGImage`.
- Downscale if width > 1920 (preserve aspect ratio) — keeps request body small and token cost sane. Moonshot recommends max 4k; 1920 is our conservative cap.
- Encode as JPEG (default) or PNG via `NSBitmapImageRep`.
- Write to Screenshots dir with ISO8601 timestamp filename.
- Return a `ToolOutput` (see §5) that carries both text (`"Screenshot saved to <path> (<w>×<h>, <bytes> bytes)"`) and the image bytes for attachment.

### Permissions
`ScreenCaptureKit` requires **Screen Recording** (TCC). Add to `PermissionsChecker.swift`:
- `isScreenRecordingGranted() -> Bool` via `CGPreflightScreenCaptureAccess()` (lightweight, no prompt).
- `requestScreenRecording()` via `CGRequestScreenCaptureAccess()` (triggers prompt).
- `openScreenRecordingSettings()` opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
- Wire into `PermissionsView.swift` as a new row alongside Accessibility/Full Disk Access.

Tool fails fast with a clear error ("Enable Screen Recording in System Settings → Privacy & Security") if not granted.

### Errors
`ScreenshotToolError.permissionDenied | noDisplay | captureFailed(String) | encodeFailed`.

---

## 5. How the image gets from tool → LLM

Currently `AgentTool.execute` returns a plain `String`. The tool_result block is just text. We need a typed way to carry image bytes out of a tool.

### New types — `Tama/Sources/AI/Tools/AgentTool.swift`

```swift
struct ToolImage: Sendable {
    let mediaType: String   // "image/png" or "image/jpeg"
    let data: Data
}

struct ToolOutput: Sendable {
    let text: String
    let images: [ToolImage]
    init(text: String, images: [ToolImage] = []) { ... }
}

protocol AgentTool: Sendable {
    ...
    func execute(args: [String: Any]) async throws -> ToolOutput  // was String
}
```

Migration: every existing tool wraps its current return — `return ToolOutput(text: "...")`. This is mechanical: `BashTool`, `ReadTool`, `WriteTool`, `EditTool`, `LsTool`, `FindTool`, `GrepTool`, `WebFetchTool`, `WebSearchTool`, `CreateReminderTool`, `CreateRoutineTool`, `ListSchedulesTool`, `DeleteScheduleTool`, `TaskTool`, `DismissTool`, `EndCallTool`, `BrowserTool`, `SkillTool` all change their return type.

### AgentLoop packaging — `Tama/Sources/AI/AgentLoop.swift`

In `executeTools`, after getting `ToolOutput` from the tool:

1. Truncate `output.text` as today.
2. If `output.images` is non-empty **and** `claude.currentModel.supportsVision`:
   - Build the tool_result block with **array content** including both the truncated text and each image as an Anthropic-native block:
     ```swift
     var content: [[String: Any]] = [["type": "text", "text": truncated]]
     for img in output.images {
         content.append([
             "type": "image",
             "source": [
                 "type": "base64",
                 "media_type": img.mediaType,
                 "data": img.data.base64EncodedString(),
             ],
         ])
     }
     results.append(["type": "tool_result", "tool_use_id": call.id, "content": content])
     ```
3. If vision is **not** supported by the selected model, images are discarded and only text is shipped — tool still functions, agent just can't see the pixels.

Anthropic natively supports `tool_result.content` as an array with image blocks. The request builders handle the unpack for other providers (§6).

### Request builders — conversion for non-Anthropic providers

**`ClaudeService.convertMessageToOpenAI`** — today it handles `user` messages with `tool_result` blocks by emitting a `role:"tool"` message with a string `content`. For tool_results whose content is an array:
- Extract all `type:"text"` entries → join into `role:"tool"` message text.
- Extract all `type:"image"` entries → emit a **second, separate** `role:"user"` message with a `content` array containing `{type:"image_url", image_url:{url:"data:<mt>;base64,<b64>"}}` for each image, plus a lead-in text block `{type:"text", text:"Screenshot attached from the previous tool call."}`. Moonshot accepts adjacent tool→user messages; vision is documented exactly this way.

**`CodexRequestBuilder.convertMessages`** — today emits `type:"function_call_output"` with string `output`. For array-content tool_results:
- Text parts join into the `output` string (as today).
- Image parts emit an additional `role:"user"` input with `content:[{type:"input_image", image_url:"data:<mt>;base64,<b64>"}]` appended after the `function_call_output`. The `/responses` endpoint supports multiple input items between function_call_output and the next assistant turn.

**`buildAnthropicRequest` (MiniMax)** — already passes `messages` through verbatim; no change. If MiniMax drops the image, it will respond as if text-only; acceptable since we've flagged `supportsVision = false` for all MiniMax models and won't send images there anyway.

---

## 6. System prompt update

`Tama/Sources/AI/SystemPrompt.swift` — add a bullet under "Tools & Workflow":
> - **Screenshots**: use the `screenshot` tool to capture the user's screen when you need to see what they're looking at (UI bugs, reading on-screen text, verifying visual state). The image is attached to your context automatically — you'll see it, not just the file path.

Also extend the `CallSystemPrompt.swift` tool list to mention `screenshot`.

---

## 7. Testing — integration harness using `gg auth` credentials

The user has `gg auth` configured with keys for most providers. The app itself reads from its own encrypted `provider-store.enc`, so there's no automatic shared state. Strategy:

### A. Unit tests (deterministic, always run)
New file `Tama/Tests/Tools/ScreenshotToolTests.swift`:
- Schema shape / required fields.
- Error messages for permission denied, unknown display index.
- (Can't exercise real capture in CI — no display.)

New file `Tama/Tests/AI/ImageBlockConversionTests.swift`:
- Given an internal Anthropic-style image block in a tool_result, `convertMessageToOpenAI` emits the correct `image_url` data-URL message.
- `CodexRequestBuilder.convertMessages` emits the correct `input_image` block.
- Text-only tool_results pass through unchanged.
- Mixed text+image tool_results produce both parts in the right order.

### B. Live provider smoke test — `Tama/Tests/Integration/VisionProviderTests.swift`
Gated by `#require(ProcessInfo.processInfo.environment["TAMA_RUN_VISION_TESTS"] != nil)` so CI doesn't burn tokens.

For each model with `supportsVision == true`:
1. Generate a tiny synthetic PNG in-memory (e.g. 256×256 solid `#FF6B00` with text "HELLO" drawn via CoreGraphics) — deterministic, no screen capture required.
2. Read the provider credential via `ProviderStore.shared.credential(for:)` — populated from the encrypted store that the user has already logged into via the app's onboarding flow.
3. Build a single-turn conversation with a user message: text "What is the dominant color in this image? Reply with just the hex code." + an Anthropic-style image block.
4. Call `ClaudeService.shared.sendWithTools(...)` (no tools) and assert the response contains `"FF6B00"` (case-insensitive) or the words "orange"/"red-orange".
5. Each model gets its own `@Test` function so failures are isolated per provider.

To populate credentials from `gg auth` without touching `ProviderStore.shared`, add a test-only helper `Tama/Tests/Helpers/GGAuthBridge.swift` that shells out to `gg auth get <provider>` (on macOS dev box this works; in CI env var fallback). The helper writes resulting keys into a local `ProviderStore` instance used only by the test suite.

### C. Manual in-app smoke test
After the build, run Tama, select each vision model one at a time, ask "Take a screenshot and tell me what app I have in the foreground" — the agent should call `screenshot` and describe the visible UI. Log with `os_log` subsystem `com.unstablemind.tama` category `tool.screenshot` to see the capture + the outgoing byte count.

---

## 8. File-level change summary

| File | Change |
|---|---|
| `Tama/Sources/AI/ModelRegistry.swift` | Add `supportsVision: Bool` to `ModelInfo`, set per model per §1. |
| `Tama/Sources/AI/Tools/AgentTool.swift` | Introduce `ToolImage`, `ToolOutput`; change protocol return type. |
| `Tama/Sources/AI/Tools/*.swift` (17 existing tools) | Wrap existing string return in `ToolOutput(text:)`. |
| `Tama/Sources/AI/Tools/ScreenshotTool.swift` | **New** — ScreenCaptureKit capture + JPEG/PNG encode + ToolOutput. |
| `Tama/Sources/AI/Tools/AgentTool.swift` `ToolRegistry` | Register `ScreenshotTool()` in `defaultRegistry` and `callRegistry`. |
| `Tama/Sources/AI/AgentLoop.swift` | Build tool_result with array content when images present + selected model supports vision. |
| `Tama/Sources/AI/ClaudeService.swift` | Extend `convertMessageToOpenAI` to handle image blocks in tool_result → emit follow-up user message with `image_url`. |
| `Tama/Sources/AI/CodexRequestBuilder.swift` | Extend `convertMessages` to emit `input_image` blocks for image content in tool_results. |
| `Tama/Sources/AI/SystemPrompt.swift` | Document screenshot tool for the agent. |
| `Tama/Sources/AI/CallSystemPrompt.swift` | Add `screenshot` to the tool enumeration. |
| `Tama/Sources/Permissions/PermissionsChecker.swift` | Screen Recording permission methods. |
| `Tama/Sources/Permissions/PermissionsView.swift` | New row for Screen Recording. |
| `Tama/Tests/Tools/ScreenshotToolTests.swift` | **New** — schema + error paths. |
| `Tama/Tests/AI/ImageBlockConversionTests.swift` | **New** — per-provider format conversion. |
| `Tama/Tests/Integration/VisionProviderTests.swift` | **New** — gated live API tests per vision model. |
| `Tama/Tests/Helpers/GGAuthBridge.swift` | **New** — shells out to `gg auth get <provider>` for test credentials. |

---

## Risks & verification

- **Protocol change ripples**: changing `AgentTool.execute` return type touches every tool and every test. Mitigation: keep the change purely mechanical (wrap existing returns) and run `swiftlint` + `xcodebuild` between each file.
- **Screen Recording TCC prompt**: first call to `SCShareableContent.current` triggers the prompt. Pre-flight check via `CGPreflightScreenCaptureAccess()` and short-circuit with a friendly error if denied.
- **Base64 payload size**: JPEG @ q85, 1920-wide cap keeps typical screenshots under ~500 KB encoded → ~700 KB base64. Well under Moonshot's 100 MB limit, fine for Codex/Anthropic too.
- **MiniMax silent-drop**: the `/anthropic` endpoint ignores image blocks. We don't ship images there (flagged `supportsVision = false`), so no wasted bandwidth.
- **Xiaomi Token Plan**: same — `supportsVision = false` until verified otherwise.
- **Retina capture size**: `display.width * scale` can be 5120×2880 on a 27" iMac. Downscale to max-width 1920 before encoding; verify with `os_log` byte counts.
- **Verification**: green `xcodebuild` + green unit test suite + manual "take a screenshot and describe my screen" on at least Moonshot + one OpenAI model.

---

## Steps

1. Add `supportsVision: Bool` field to `ModelInfo` in `Tama/Sources/AI/ModelRegistry.swift` and populate per-model values per §1 (`kimi-k2.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex` = true; all others = false).
2. Define `ToolImage` and `ToolOutput` structs in `Tama/Sources/AI/Tools/AgentTool.swift` and change the `AgentTool` protocol's `execute(args:)` return type from `String` to `ToolOutput`.
3. Migrate all 17 existing tools (`BashTool`, `ReadTool`, `WriteTool`, `EditTool`, `LsTool`, `FindTool`, `GrepTool`, `WebFetchTool`, `WebSearchTool`, `CreateReminderTool`, `CreateRoutineTool`, `ListSchedulesTool`, `DeleteScheduleTool`, `TaskTool`, `DismissTool`, `EndCallTool`, `BrowserTool`, `SkillTool`) to wrap their existing string returns in `ToolOutput(text:)`.
4. Update existing tool tests in `Tama/Tests/Tools/` to unwrap `.text` from the new `ToolOutput` return.
5. Add Screen Recording permission methods to `Tama/Sources/Permissions/PermissionsChecker.swift` (`isScreenRecordingGranted`, `requestScreenRecording`, `openScreenRecordingSettings`) using `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`.
6. Add a Screen Recording row to `Tama/Sources/Permissions/PermissionsView.swift` mirroring the Accessibility and Full Disk Access rows.
7. Create `Tama/Sources/AI/Tools/ScreenshotTool.swift` implementing full-screen capture via `SCShareableContent` + `SCContentFilter(display:excludingWindows:)` + `SCScreenshotManager.captureImage(contentFilter:configuration:)`, with JPEG encoding (default q85), 1920-width downscale cap, write to `PromptPanelController.screenshotsDirectory`, and return `ToolOutput(text: "Screenshot saved to <path> (<w>×<h>, <bytes> bytes)", images: [ToolImage(mediaType: "image/jpeg", data: ...)])`.
8. Register `ScreenshotTool()` in both `ToolRegistry.defaultRegistry` and `ToolRegistry.callRegistry` in `Tama/Sources/AI/Tools/AgentTool.swift`.
9. Update `AgentLoop.executeTools` in `Tama/Sources/AI/AgentLoop.swift` to build `tool_result.content` as an array with both text and `{type:"image", source:{type:"base64", ...}}` blocks when the tool returned images AND `ClaudeService.shared.currentModel.supportsVision` is true; otherwise discard images and emit text-only as today.
10. Extend `ClaudeService.convertMessageToOpenAI` in `Tama/Sources/AI/ClaudeService.swift` to detect image blocks inside `tool_result.content` arrays and emit an additional `role:"user"` message with `{type:"image_url", image_url:{url:"data:<mt>;base64,<b64>"}}` content after the `role:"tool"` message.
11. Extend `CodexRequestBuilder.convertMessages` in `Tama/Sources/AI/CodexRequestBuilder.swift` to detect image blocks inside `tool_result.content` arrays and emit an additional user input with `content:[{type:"input_image", image_url:"data:<mt>;base64,<b64>"}]` after the `function_call_output`.
12. Add a "Screenshots" bullet to `Tama/Sources/AI/SystemPrompt.swift` and mention `screenshot` in the tool list of `Tama/Sources/AI/CallSystemPrompt.swift`.
13. Create `Tama/Tests/Tools/ScreenshotToolTests.swift` with input-schema assertions, missing-permission error path, and invalid-display-index error path.
14. Create `Tama/Tests/AI/ImageBlockConversionTests.swift` asserting correct format conversion for Moonshot (OpenAI chat completions), Codex (Responses), and Anthropic (MiniMax pass-through) given mixed text+image tool_results.
15. Create `Tama/Tests/Helpers/GGAuthBridge.swift` that shells out to `gg auth get <provider>` and returns the API key string (with env var fallback `TAMA_<PROVIDER>_KEY`).
16. Create `Tama/Tests/Integration/VisionProviderTests.swift` with one `@Test` per vision-capable model that generates a synthetic colored PNG, hits the real API via `ClaudeService`, and asserts the response mentions the expected color. Gate the whole suite on `ProcessInfo.processInfo.environment["TAMA_RUN_VISION_TESTS"] != nil`.
17. Run `xcodegen generate && xcodebuild -project Tama.xcodeproj -scheme Tama -configuration Debug build` and `swiftlint lint` to verify clean compile and lint pass.
18. Run `TAMA_RUN_VISION_TESTS=1 xcodebuild -scheme Tama -destination 'platform=macOS' test` to exercise the live vision tests against each configured provider.
