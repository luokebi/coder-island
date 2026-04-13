# Coder Island

A macOS menu bar utility that monitors Claude Code and Codex CLI sessions in real-time. See what your agents are doing, answer their questions, and track usage — all from the notch.

![Coder Island Expanded Panel](docs/images/1-2.jpg)

## Features

- **Live Session Monitoring** — See every Claude Code and Codex session running on your machine, with real-time status updates via hooks
- **Permission Routing** — Intercepts permission prompts and shows them in a native banner. Allow, deny, or allow-always without switching to the terminal
- **Question Answering** — When Claude asks a question, see it with clickable options. Answer directly from the UI
- **Usage Tracking** — Monitor your 5-hour and weekly rate limits for both Claude and Codex at a glance
- **Terminal Jump** — Click any session to jump directly to its terminal window (Warp, Ghostty, iTerm2, VS Code, Terminal.app)
- **Sound Notifications** — Customizable sound effects for permissions, questions, and completions (Mario, Pop, Chime presets or custom)
- **Plan Mode Detection** — Shows "Waiting for plan approval" when Claude enters plan mode

### Compact Bar

![Compact Bar](docs/images/1-1.jpg)

### Ask Question

![Ask Question](docs/images/1-3.jpg)

### Permission Request

![Permission Request](docs/images/1-4.jpg)

## Install

1. Download `CoderIsland-1.0.0.dmg` from [Releases](https://github.com/luokebi/coder-island/releases)
2. Drag Coder Island to Applications
3. Launch — it appears in the macOS notch area
4. Open Settings and enable "Answer questions & permissions in Coder Island" for hook integration

> Users may need to right-click → Open on first launch to bypass Gatekeeper.

## Requirements

- macOS 14 Sonoma or later

## Build from Source

```bash
# Debug build
xcodebuild -project CoderIsland.xcodeproj -scheme CoderIsland -configuration Debug build

# Package DMG
./scripts/package-dmg.sh
```

## How It Works

Coder Island discovers sessions by scanning `~/.claude/sessions/` and `~/.codex/sessions/`. When hooks are enabled, it installs lightweight shell scripts that relay Claude Code events to the app via a Unix domain socket — zero latency.

The app lives in the macOS notch area (or menu bar on non-notch Macs). Hover to expand, click a session to jump to its terminal.

## Tech

- Swift & SwiftUI
- Unix Socket IPC
- ~11K lines of code

## License

MIT
