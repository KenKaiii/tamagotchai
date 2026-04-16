# Virtual Cursor — agent-controlled pointer for guided tutorials

## Goal

Give the agent a **floating fake cursor** that it can move around the user's
screen to point at things ("click here", "this menu is what you want") without
ever touching the user's real cursor. The user keeps full control of their
mouse the whole time — the virtual cursor is purely visual, click-through, and
overlays everything.

This is distinct from "computer use" agents that hijack the cursor to do work
*for* the user. This is **tutor mode** — the agent shows, the user does.

## What it should look like (UX)

1. User: "Show me how to export from Photoshop."
2. Agent: takes a `screenshot`, sees the screen, identifies the File menu.
3. Agent: speaks "click File in the top-left" AND calls `point` with the File
   menu's coordinates.
4. A glowing virtual cursor (Tama-themed colour) **fades in** at roughly where
   the user's real cursor is, then **smoothly animates** to the File menu over
   ~600ms with an ease-in-ease-out curve, ending with a soft pulse ring at the
   target.
5. Cursor stays visible for ~3 seconds, then fades out (unless the agent calls
   `point` again — in which case it animates from the current position to the
   new target).

The user's real cursor never moves. The user can click while the virtual
cursor is on screen.

## Reference implementations

Already studied. Patterns we'll borrow from:

| Repo | Pattern |
|---|---|
| `lihaoyun6/QuickRecorder` (`MousePointer`) | Borderless `NSPanel` with `level = .screenSaver`, `ignoresMouseEvents = true`, `backgroundColor = .clear`, hosting a SwiftUI cursor view |
| `farouqaldori/claude-island` | Toggleable mouse events on a transparent panel (we'll keep ours always click-through) |
| `MonitorControl/MonitorControl` | `level = .screenSaver` + `collectionBehavior = [.stationary, .canJoinAllSpaces]` for cross-Space stability |
| `lwouis/alt-tab-macos` | `NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }` for screen detection |
| `JanX2/ShortcutRecorder` (`CursorView`) | Using `NSCursor.arrow.image` (real macOS cursor as `NSImage`) as the visual |
| `superhighfives/pika` (`ColorPickOverlayWindow`) | Pulse/crosshair animations on overlay panels |
| Tama's own `NotchActivityIndicator` | Lifecycle pattern, `MainActor` enum, lazy panel creation, `CABasicAnimation` use |

## Architecture

### Files to add

- **`tama/Sources/VirtualCursor/VirtualCursorController.swift`** —
  `@MainActor` enum, public API:
  - `show(at: CGPoint, on: NSScreen)` — appear at a point
  - `move(to: CGPoint, on: NSScreen, duration: TimeInterval)` — animate
  - `pulse()` — ripple at current position
  - `hide(after: TimeInterval)` — fade out after delay
  - Owns one `NSPanel` per screen, lazily created on first use per screen
  - Tracks current displayed position so consecutive `move` calls animate from
    the current position (no teleport)
  - Cancels any pending hide / pulse / move animations cleanly

- **`tama/Sources/VirtualCursor/VirtualCursorPanel.swift`** — small subclass
  containing:
  - The cursor `NSImageView` (using `NSCursor.arrow.image` resized to 32pt,
    tinted with Tama's brand orange via template + `contentTintColor`, with a
    subtle white outline for visibility on dark backgrounds)
  - The pulse `CAShapeLayer` for the click ripple
  - A `CABasicAnimation` helper for smooth movement with bezier easing

- **`tama/Sources/AI/Tools/PointTool.swift`** — agent tool, see schema below

- **`tama/Tests/Tools/PointToolTests.swift`** — schema tests, normalized-coord
  conversion math tests, error cases (out-of-range coords, invalid display
  index, no displays)

- **`tama/Tests/VirtualCursor/VirtualCursorControllerTests.swift`** — unit
  tests for the coordinate-conversion helpers (normalized → AppKit per-screen),
  not the panel itself (panels need a display)

### Files to modify

- `tama/Sources/AI/Tools/AgentTool.swift` — register `PointTool()` in
  `defaultRegistry()` and `callRegistry()`. Tool count goes 18 → 19.
- `tama/Sources/AI/SystemPrompt.swift` — describe `point` and how to use it
  with screenshots.
- `tama/Sources/AI/CallSystemPrompt.swift` — voice-specific hint: "narrate
  before pointing — say what you're pointing at, then call `point`."
- `tama/Sources/PromptPanel/ToolIndicatorView.swift` — display name for
  `point` → "Pointing…"
- `tama/Tests/Registry/ToolRegistryTests.swift` — bump expected tool count
  from 18 to 19, add `point` to `expectedNames`, add `point` to call-registry
  test.

## `point` tool — schema

```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number",
      "minimum": 0.0,
      "maximum": 1.0,
      "description": "Horizontal position as fraction of screen width. 0 = left edge, 1 = right edge."
    },
    "y": {
      "type": "number",
      "minimum": 0.0,
      "maximum": 1.0,
      "description": "Vertical position as fraction of screen height. 0 = top edge, 1 = bottom edge."
    },
    "display": {
      "type": "integer",
      "minimum": 0,
      "description": "0-based display index (default: 0 = main). Match the index used when calling `screenshot`."
    },
    "label": {
      "type": "string",
      "description": "Optional short label shown next to the cursor (e.g. \"File menu\")."
    },
    "pulse": {
      "type": "boolean",
      "description": "Show a click-ripple at the target after arriving (default: true)."
    },
    "hold_seconds": {
      "type": "number",
      "minimum": 0.5,
      "maximum": 30,
      "description": "How long the cursor stays visible after arriving (default: 3.0)."
    }
  },
  "required": ["x", "y"]
}
```

### Why normalized coordinates (0-1)?

Robust across:
- Different display resolutions (1080p, 4K, 5K, 6K)
- Retina vs non-Retina (no scale-factor math)
- Screenshot downscaling (`ScreenshotTool` caps at 1920px wide; vision models
  work in that downscaled space, but `point` doesn't need to know)
- Multi-display setups (each display is its own 0-1 space)

The model already does this kind of estimation when describing where things
are visually ("the button is in the top-right, around x=0.85, y=0.10"). Pixel
coords are tied to the screenshot dimensions, which is more brittle.

The `display` arg matches `ScreenshotTool`'s `display` arg so the agent knows
which screen it's targeting.

### Why not let the model pick pixel coords from the screenshot?

It works but it's fragile: the screenshot is downscaled before being sent to
the model, so the model would need to know the pre-scale → display point
conversion. Normalized fractions sidestep all of it. We tell the model in the
system prompt: "Point at things by estimating where they are as a fraction of
the screen — top-left is (0,0), bottom-right is (1,1)."

## Coordinate conversion math

```swift
func appKitPoint(forNormalized x: Double, y: Double, on screen: NSScreen) -> CGPoint {
    let frame = screen.frame
    return CGPoint(
        x: frame.minX + x * frame.width,
        y: frame.maxY - y * frame.height  // y flipped: 0 = top in agent space
    )
}
```

This works regardless of:
- Screen position in the global desktop (`frame.minX`/`minY` may be negative
  for screens to the left of/below main)
- Backing scale factor (we work in points, not pixels)
- Notch presence (the notch is a visual cutout but doesn't affect `frame`)

Test cases (in `VirtualCursorControllerTests`):
- Centre of a 1920x1080 screen at origin → (960, 540)
- Top-left → (0, 1080)
- Bottom-right → (1920, 0)
- Centre of a screen at offset (1920, 0) → (2880, 540)

## NSPanel configuration

Same shape as Tama's existing `NotchActivityIndicator`, with these specifics:

```swift
let panel = NSPanel(
    contentRect: screen.frame,            // full-screen overlay
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isFloatingPanel = true
panel.level = .screenSaver               // above menu bar, dock, fullscreen apps
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = false
panel.ignoresMouseEvents = true          // CRITICAL: real cursor passes through
panel.hidesOnDeactivate = false
panel.collectionBehavior = [
    .canJoinAllSpaces,                   // visible on every Space
    .fullScreenAuxiliary,                // visible over fullscreen apps
    .stationary,                         // doesn't move with Spaces transitions
    .ignoresCycle,                       // doesn't appear in Cmd-Tab
]
panel.isReleasedWhenClosed = false
```

`level = .screenSaver` is the same level QuickRecorder uses for its mouse
pointer overlay — it sits above the menu bar (`.mainMenu`), the dock
(`.dock`), and even fullscreen apps when paired with `.fullScreenAuxiliary`.

## Cursor visual

- **Image**: `NSCursor.arrow.image` resized to 32x32 logical points, applied as
  a CALayer's `contents`. Real macOS cursor → user immediately recognises the
  shape.
- **Tint**: overlay a Tama-orange (`NSColor.systemOrange`) at 70% opacity so
  it's distinguishable from the real cursor.
- **Outline**: 2px white outline via a slightly larger background layer, so it
  reads on both light and dark backgrounds.
- **Pulse ring** (when `pulse: true`):
  - `CAShapeLayer` circle, starting at radius 8, animating to radius 32 over
    0.6s with opacity 0.8 → 0.0
  - Uses `CABasicAnimation` on `path`, `opacity`
  - Tama-orange stroke, 3px line width

## Animation

Move animation:
```swift
let move = CABasicAnimation(keyPath: "position")
move.fromValue = NSValue(cgPoint: currentPosition)
move.toValue = NSValue(cgPoint: targetPosition)
move.duration = duration                          // default 0.6s
move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
move.fillMode = .forwards
move.isRemovedOnCompletion = false
cursorLayer.add(move, forKey: "move")
cursorLayer.position = targetPosition             // commit final position
```

Cancel-on-replace:
```swift
cursorLayer.removeAnimation(forKey: "move")
// presentation layer's position is the actual current displayed position
let currentDisplayed = cursorLayer.presentation()?.position ?? cursorLayer.position
// then animate from currentDisplayed to new target
```

## Multi-display handling

- One `NSPanel` per `NSScreen`, lazily created. Stored in a
  `[CGDirectDisplayID: NSPanel]` dictionary keyed by display ID (stable across
  hot-plug / reordering).
- When a `point` call targets `display = N`:
  1. Resolve `screen = NSScreen.screens[safe: N] ?? NSScreen.main`
  2. Look up panel by `screen.displayID`; create if missing
  3. Position cursor in that panel using the per-screen normalized→AppKit math
  4. Hide cursor in OTHER displays' panels (single virtual cursor at a time)
- Listen for `NSApplication.didChangeScreenParametersNotification` — invalidate
  cached panels when displays are added/removed.
- Edge case: `display` arg is out of range → throw a clear error
  (`PointToolError.invalidDisplay(index, available: NSScreen.screens.count)`)

## Lifecycle

- Lazy creation: panels are only created on first `point` call per display.
- Stays alive once created (no need to recreate; cheap to keep around).
- `hide(after:)` schedules a fade-out timer. Subsequent `move` cancels the
  pending hide (cursor stays visible while agent is actively pointing).
- App quit: panels are released cleanly via `NSPanel.orderOut(nil)`.

## System prompt updates

Add to `SystemPrompt.swift`:

```
- **Pointing things out (tutor mode)**: use the `point` tool to highlight
  spots on the user's screen with a virtual cursor (their real cursor stays
  put). Take a `screenshot` first to see what you're pointing at, then call
  `point` with normalized coords (0-1, top-left origin). Pair with a verbal
  hint: "click the File menu in the top-left" → `point { x: 0.05, y: 0.02 }`.
  Use this when teaching the user how to do something — DO NOT use it to do
  the thing for them.
```

Add to `CallSystemPrompt.swift`:

```
- If the user asks "how do I..." or "where's...", consider taking a
  screenshot and using `point` to visually guide them. Always SAY what
  you're pointing at before/while pointing — the cursor is silent.
```

## Testing strategy

### Unit tests (deterministic, no UI)

`PointToolTests`:
- Schema correctness (required/optional fields, ranges)
- Out-of-range coords throw / clamp
- Missing required fields throw
- Tool name/description/registry presence

`VirtualCursorControllerTests`:
- `appKitPoint(forNormalized:y:on:)` math — table-driven test for centre,
  corners, off-centre screens
- `screen(forIndex:)` — returns correct screen, falls back gracefully
- `displayID(forIndex:)` — stable per index

`ToolRegistryTests` updates:
- Tool count is 19 (was 18)
- `point` is in expected names
- `point` is in call registry

### Manual integration test

After implementation, restart the app and do a real call:

1. Voice call with vision-capable model (Kimi K2.5)
2. Say: "where's the menu bar in this app?"
3. Expected: agent takes screenshot, says "The menu bar is at the top of the
   screen", virtual cursor animates from centre to top-left, pulses, fades
4. Verify: real cursor never moved, virtual cursor was visibly distinct
   (orange tint), animation was smooth

5. Multi-display test: drag a second display to the left of the main one,
   ask "point at the bottom-right corner of my second screen". Expect the
   cursor to appear on display 1 at the bottom-right.

6. Permission check: feature should work with NO new permissions (no
   Accessibility needed since we're not posting CGEvents). Confirm.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Cursor obscures the real cursor and confuses the user | Different tint colour (orange vs system arrow), always smaller/lighter weight |
| Cursor stuck on screen if app crashes mid-animation | Auto-hide timer (3s default); on next launch, no panel exists — clean slate |
| Cursor blocks user's view of the thing it's pointing at | Place cursor offset 4-8pt from the actual target so the click point arrow tip lands on the target, image extends down-right |
| Different displays have different scale factors and sizes | Normalized 0-1 coords + `screen.frame` (in points) handles this for free |
| Click-through doesn't work in some apps (e.g. Stage Manager fullscreen) | `.fullScreenAuxiliary` collection behaviour + `.screenSaver` level handles 99% of cases. Document the 1% edge case in the tool description. |
| Multiple `point` calls back-to-back | Cancel pending animations, animate from the actual displayed position |
| Coordinate confusion (top-left vs bottom-left) | Tool docs + schema description explicit; conversion happens once in one place |

## Out of scope (future)

- `find_element` tool that uses AXUIElement to look up UI elements by
  accessibility label, returns coords for `point`. Powerful but needs more
  permission UX work.
- `click` / `type` tools (full computer-use agent territory) — explicit
  no-go for now; we want tutor mode, not autopilot.
- Custom Tama-mascot cursor PNG — can swap the visual later, the controller
  API stays the same.

## Steps

1. Create `tama/Sources/VirtualCursor/VirtualCursorController.swift` with the `@MainActor` enum exposing `show`, `move`, `pulse`, `hide`, plus the per-screen panel cache and `appKitPoint(forNormalized:y:on:)` math
2. Create `tama/Sources/VirtualCursor/VirtualCursorPanel.swift` with the borderless click-through panel, cursor image view (using `NSCursor.arrow.image` tinted), and pulse `CAShapeLayer`
3. Wire screen-change notifications (`NSApplication.didChangeScreenParametersNotification`) to invalidate panel cache when displays are added/removed
4. Create `tama/Sources/AI/Tools/PointTool.swift` implementing the `AgentTool` protocol with the normalized-coord schema and `display`/`label`/`pulse`/`hold_seconds` args
5. Register `PointTool()` in both `defaultRegistry()` and `callRegistry()` in `tama/Sources/AI/Tools/AgentTool.swift`
6. Add `case "point"` returning `"Pointing…"` to `ToolIndicatorView.displayName(for:)`
7. Add `point` tool guidance to `tama/Sources/AI/SystemPrompt.swift` (tutor mode usage)
8. Add `point` tool voice-specific guidance to `tama/Sources/AI/CallSystemPrompt.swift`
9. Update `tama/Tests/Registry/ToolRegistryTests.swift` — bump tool count to 19, add `point` to `expectedNames`, add `point` to call registry assertion
10. Write `tama/Tests/Tools/PointToolTests.swift` covering schema, arg validation, range clamping, error cases
11. Write `tama/Tests/VirtualCursor/VirtualCursorControllerTests.swift` covering the coordinate conversion math (centre, corners, off-centre screens, multi-display offsets)
12. Run `xcodegen generate`, `swiftformat`, `swiftlint`, `xcodebuild build`, `xcodebuild test` — all green
13. Build, restart Tama, do a manual smoke test: voice call → "show me the menu bar" → confirm the orange virtual cursor animates to the top-left, real cursor stays put
