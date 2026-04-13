# 🐱 Tama

<p align="center">
  <img src="https://raw.githubusercontent.com/KenKaiii/tamagotchai/main/assets/icon_1024.png" alt="Tama" width="200">
</p>

<p align="center">
  <strong>Your AI pet that lives in the menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/KenKaiii/tamagotchai/releases/latest"><img src="https://img.shields.io/github/v/release/KenKaiii/tamagotchai?include_prereleases&style=for-the-badge" alt="GitHub release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <a href="https://youtube.com/@kenkaidoesai"><img src="https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white" alt="YouTube"></a>
  <a href="https://skool.com/kenkai"><img src="https://img.shields.io/badge/Skool-Community-7C3AED?style=for-the-badge" alt="Skool"></a>
</p>

**Tama** is a macOS menu-bar AI assistant powered by Claude. It lives in your menu bar with an animated mascot, opens a floating prompt panel with ⌥Space, and runs a full agentic tool loop — bash, file editing, web fetching, scheduling, and more. Built natively in Swift 6 with AppKit and SwiftUI.

No dock icon. No Electron. Just a lightweight, always-there AI assistant.

---

## 🧠 Why this exists

AI assistants shouldn't be a browser tab you have to find. They should be *right there* — one hotkey away, living alongside your workflow.

Tama sits in your menu bar, ready to go. Hit ⌥Space and a floating panel appears over whatever you're doing. Ask it something, tell it to run a command, edit a file, fetch a webpage, set a reminder. It uses Claude under the hood with a full agent loop that can chain tools together to complete multi-step tasks.

Plus it has a little animated mascot. Because why not.

---

## ✨ What it actually does

### Floating prompt panel
Hit ⌥Space from anywhere. A glass-styled floating panel appears over your current app. Type a message, get a streamed response with full markdown rendering, syntax-highlighted code blocks, and copy buttons. It stays out of your way when you don't need it.

### Full agent tool loop
Not just chat. Tama runs a multi-turn agent loop (up to 50 turns) with real tools:
- **Bash** — run shell commands directly
- **Read / Write / Edit** — view and modify files on your system
- **Grep / Find / Ls** — search and navigate your filesystem
- **Web Fetch** — pull content from URLs with SSRF protection

Ask it to refactor a file, search your codebase, run a build, or scrape a webpage. It chains tools together to get the job done.

### Scheduled reminders & routines
Create reminders that fire as native macOS notifications. Set up routines — scheduled prompts that trigger full agent executions automatically:
- "Remind me to review PRs in 2 hours"
- "Every morning at 9am, check the weather and summarize my calendar"
- "Run this cleanup script every Friday at 5pm"

Supports one-off times, durations, and cron expressions.

### Animated Rive mascot
A little companion that reacts to what's happening — idle, typing, waiting, responding. It lives in the panel and gives the app personality. Built with Rive animations.

### Native macOS experience
Built with AppKit (NSPanel, NSTextView) and SwiftUI. No web views, no Electron wrapper. Feels like it belongs on your Mac. Runs as an LSUIElement — menu bar only, no dock icon.

### OAuth login with Claude
Authenticate via Anthropic's OAuth2 PKCE flow. Credentials are encrypted and persisted securely. No API key pasting required.

---

## 🚀 Getting started

### Download

| Mac | Link |
|-----|------|
| Apple Silicon (M1/M2/M3/M4) | [Download](https://github.com/KenKaiii/tamagotchai/releases/latest) |

### Setup

1. Drag to Applications, launch it
2. It shows up in your menu bar
3. Click it → AI Settings → log in with your Anthropic account
4. Hit ⌥Space and start chatting

That's it.

---

## 🛠️ For developers

### Requirements
- macOS 15.0+
- Xcode 16+ with Swift 6.0
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build from source

```bash
git clone https://github.com/KenKaiii/tamagotchai.git
cd tamagotchai

# Generate Xcode project
xcodegen generate

# Build
xcodebuild -project Tama.xcodeproj -scheme Tama -configuration Debug build
```

### Stack
- **Language:** Swift 6.0 (strict concurrency)
- **Platform:** macOS 15+, LSUIElement menu-bar app
- **UI:** AppKit (NSPanel, NSTextView) + SwiftUI
- **Dependencies:** RiveRuntime (mascot animations), Highlightr (syntax highlighting), Kokoro (TTS)
- **Build:** XcodeGen (`project.yml` → .xcodeproj), SPM for packages

### Lint & format

```bash
# Lint
swiftlint lint --config .swiftlint.yml

# Format (check)
swiftformat --lint --config .swiftformat Tama/Sources

# Format (auto-fix)
swiftformat --config .swiftformat Tama/Sources
```

---

## 🔒 Privacy

- Everything runs locally on your Mac
- Conversations are sent to Anthropic's API (that's how Claude works)
- OAuth credentials encrypted and stored locally
- No analytics, no telemetry, no tracking

---

## 👥 Community

- [YouTube @kenkaidoesai](https://youtube.com/@kenkaidoesai) — tutorials and demos
- [Skool community](https://skool.com/kenkai) — come hang out

---

## 📄 License

MIT

---

<p align="center">
  <strong>A native macOS AI assistant that's always one hotkey away.</strong>
</p>

<p align="center">
  <a href="https://github.com/KenKaiii/tamagotchai/releases/latest"><img src="https://img.shields.io/badge/Download-Latest%20Release-blue?style=for-the-badge" alt="Download"></a>
</p>
