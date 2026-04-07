# Tama

macOS menu-bar AI assistant powered by Claude. Floating prompt panel (⌥Space), agentic tool loop (bash, read, write, edit, grep, find, ls, web_fetch), animated Rive mascot. Swift 6, macOS 14+, no dock icon.

## Project Structure

```
tama/Sources/
├── TamaApp.swift               # @main entry, menu bar extra, AppDelegate
├── ContentView.swift           # Root SwiftUI view
├── AI/                         # Claude API integration
│   ├── ClaudeService.swift     # HTTP client, streaming, OAuth token management
│   ├── ClaudeOAuth.swift       # OAuth2 PKCE login flow
│   ├── ClaudeCredentials.swift # Encrypted credential persistence
│   ├── ClaudeModels.swift      # API request/response types
│   ├── AgentLoop.swift         # Multi-turn tool execution loop (max 50 turns)
│   ├── StreamParser.swift      # SSE stream parser
│   └── Tools/                  # Agent tool implementations
│       ├── AgentTool.swift     # Tool protocol + ToolRegistry
│       ├── BashTool.swift      # Shell command execution
│       ├── ReadTool.swift      # File reading (cat -n style)
│       ├── WriteTool.swift     # File writing
│       ├── EditTool.swift      # Search-and-replace editing
│       ├── GrepTool.swift      # Regex file search
│       ├── FindTool.swift      # Glob file finder
│       ├── LsTool.swift        # Directory listing
│       ├── WebFetchTool.swift  # URL fetcher with SSRF protection
│       ├── CreateReminderTool.swift  # Create scheduled reminder notifications
│       ├── CreateRoutineTool.swift   # Create scheduled LLM-triggered routines
│       ├── ListSchedulesTool.swift   # List active schedules
│       └── DeleteScheduleTool.swift  # Delete a schedule by name
├── Scheduler/                  # Reminder & routine scheduling system
│   ├── ScheduleParser.swift    # Schedule string parsing (durations, cron, datetime)
│   └── ScheduleStore.swift     # Job persistence, polling timer, execution
├── PromptPanel/                # Floating chat panel UI
│   ├── FloatingPanel.swift     # NSPanel subclass, streaming display
│   ├── PromptPanelController.swift # Panel lifecycle, hotkey, submit handling
│   ├── MarkdownRenderer.swift  # Markdown → NSAttributedString
│   ├── ResponseTextView.swift # Code block overlays, copy buttons
│   ├── SkeletonView.swift     # Loading shimmer placeholder
│   ├── ToolIndicatorView.swift # Active tool indicator
│   └── PanelHelperViews.swift # Shared panel subviews
├── Mascot/                    # Animated Rive mascot (idle/typing/waiting/responding)
├── Login/                     # OAuth login window + SwiftUI view
├── Permissions/               # Accessibility & Full Disk Access checker
└── UI/                        # Shared components (GlassButton, DropdownPanel)
```

## Tech Stack

- **Language**: Swift 6.0 (strict concurrency)
- **Platform**: macOS 14+, LSUIElement menu-bar app
- **UI**: AppKit (NSPanel, NSTextView) + SwiftUI
- **Dependencies**: RiveRuntime (mascot animations), Highlightr (syntax highlighting)
- **Build**: XcodeGen (`project.yml` → .xcodeproj), SPM for packages
- **Logging**: Apple Unified Logging (`os.Logger`, subsystem `com.unstablemind.tama`)

## Build & Quality Commands

```bash
# Regenerate Xcode project after changing project.yml
xcodegen generate

# Build
xcodebuild -project Tama.xcodeproj -scheme Tama -configuration Debug build

# Lint (runs automatically on build via Xcode script phase)
swiftlint lint --config .swiftlint.yml

# Format check (dry run — also runs on build)
swiftformat --lint --config .swiftformat Tama/Sources

# Format (auto-fix)
swiftformat --config .swiftformat Tama/Sources
```

## Logging

All logging uses `os.Logger` with subsystem `com.unstablemind.tama`. Categories by file:

| Category | File(s) |
|---|---|
| `app` | TamaApp.swift |
| `controller` | PromptPanelController.swift |
| `panel` | FloatingPanel.swift |
| `claude` | ClaudeService.swift |
| `oauth` | ClaudeOAuth.swift |
| `credentials` | ClaudeCredentials.swift |
| `stream` | StreamParser.swift |
| `agent` | AgentLoop.swift |
| `tool.bash` | BashTool.swift |
| `tool.read` | ReadTool.swift |
| `tool.write` | WriteTool.swift |
| `tool.edit` | EditTool.swift |
| `tool.grep` | GrepTool.swift |
| `tool.find` | FindTool.swift |
| `tool.ls` | LsTool.swift |
| `tool.web` | WebFetchTool.swift |
| `tool.reminder` | CreateReminderTool.swift |
| `tool.routine` | CreateRoutineTool.swift |
| `tool.schedules` | ListSchedulesTool.swift, DeleteScheduleTool.swift |
| `scheduler` | ScheduleStore.swift |
| `permissions` | PermissionsChecker.swift |

```bash
# Stream all app logs in Terminal
log stream --predicate 'subsystem == "com.unstablemind.tama"' --level debug

# Filter by category (e.g. agent loop only)
log stream --predicate 'subsystem == "com.unstablemind.tama" AND category == "agent"' --level debug

# Filter tools only
log stream --predicate 'subsystem == "com.unstablemind.tama" AND category BEGINSWITH "tool."' --level debug

# Search recent logs (last 5 minutes)
log show --predicate 'subsystem == "com.unstablemind.tama"' --last 5m --level debug
```

Also viewable in **Console.app** → filter by subsystem `com.unstablemind.tama`.

## Code Rules

- One component per file, file name matches primary type
- `@MainActor` on all UI-touching classes; tools are `@unchecked Sendable`
- Errors as `LocalizedError` enums scoped to their type
- Use `os.Logger` for all logging — never `print()` or `NSLog()`
- 4-space indent, 120 char max line width, trailing commas always
- No dead code, no TODOs, no commented-out code
