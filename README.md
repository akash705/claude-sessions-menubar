# Claude Sessions

A macOS menubar app that surfaces your active [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions at a glance.

See which sessions are running, which are waiting on you for permission, read message history live, and jump to the exact terminal/IDE window hosting any session — all without leaving your keyboard.

## Features

- **Session list** grouped by project, sorted by last activity.
- **Status filter pills**: Running · Pending · Idle · Done · Error. Counts update in real time.
- **Live message history** — click a row to open a dedicated window that streams new messages as Claude writes them to disk (FS events + 0.5 s polling fallback).
- **Permission detection** — when Claude requests a tool use that you haven't answered, the session is flagged with an orange `permission` badge and the tool name; the history window shows a prominent banner with one-click actions.
- **Focus the terminal** hosting a session. For iTerm2 and Terminal.app, the specific tab is selected by TTY. For IDE terminals (Cursor, VSCode, etc.), the correct instance and workspace window is raised via the Accessibility API.
- **Send a message via the Claude bridge** — if you've run `/remote-control` in a session, a paperplane button opens `https://claude.ai/code/<bridgeSessionId>` in your browser.
- **Newest-first history** with user / assistant / tool_use / tool_result / thinking / system entries all rendered with distinct styling.
- Right-click any row for a quick menu: Open History · Focus Terminal · Send Message · Reveal Transcript in Finder · Copy Session ID.

## How it works

The app is a **read-only observer** of Claude Code's on-disk state under `~/.claude/`. It never modifies your sessions, sends keystrokes, or talks to the Claude API.

| Source | Purpose |
|---|---|
| `~/.claude/sessions/<pid>.json` | Live-session pointer. Presence + live PID = session is running. Also contains the `bridgeSessionId` when `/remote-control` is active. |
| `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | Full message transcript. Tailed for list preview; read fully for the history window. |
| `~/.claude/ide/*.lock` | One per connected IDE *window* — lets us match a session's cwd to a specific Cursor/VSCode window for precise focus. |

### Status rules

| Status | Condition |
|---|---|
| **Running** | Live PID alive **and** last transcript entry is an assistant message within 2 minutes |
| **Pending** | Live PID alive **and** last entry is a user message or tool_result (Claude is idle / awaiting hook) |
| **Idle** | Live PID alive **and** no transcript activity for 2+ minutes |
| **Done** | No live PID; transcript modified within the last 7 days |
| **Error** | Recent `tool_result` with `is_error: true` (overrides other statuses) |

Sessions whose transcript hasn't been touched in 7+ days are excluded.

## Requirements

- macOS 14 (Sonoma) or later
- [Xcode 15+](https://developer.apple.com/xcode/) (the command-line tools alone aren't enough for `MenuBarExtra`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to regenerate the project from `project.yml`)

## Setup

```sh
brew install xcodegen
git clone https://github.com/akash705/claude-sessions-menubar.git
cd claude-sessions-menubar
xcodegen generate
open ClaudeSessions.xcodeproj
```

In Xcode:

1. Select the `ClaudeSessions` target → **Signing & Capabilities** → pick your team (or *Sign to Run Locally*).
2. Hit **⌘R**. A ✨ icon appears in the menubar.

## Permissions

On first use of "Focus Terminal" for an IDE session, macOS will prompt for **Accessibility** access. Grant it in:

**System Settings → Privacy & Security → Accessibility**

This is only needed to raise the correct IDE *window* (Cursor, VSCode, etc.) when you have multiple open. Standalone terminals (iTerm2, Terminal.app) use AppleScript instead and don't need Accessibility.

## Project layout

```
ClaudeSessions/
├── ClaudeSessionsApp.swift          # @main — MenuBarExtra + history WindowGroup
├── Models/
│   ├── Session.swift                # Session struct + Status enum
│   └── TranscriptEntry.swift        # JSONL line + block decoder
├── Services/
│   ├── ClaudePaths.swift            # ~/.claude/* URL helpers
│   ├── LiveSessionIndex.swift       # reads ~/.claude/sessions/*.json
│   ├── IDEIndex.swift               # reads ~/.claude/ide/*.lock
│   ├── TranscriptReader.swift       # backward-chunked JSONL tail + full read
│   ├── SessionScanner.swift         # walks projects/, builds [Session]
│   ├── StatusResolver.swift         # the status rules above
│   ├── ProcessLiveness.swift        # kill(pid, 0)
│   ├── ProcessTree.swift            # libproc ppid walk, finds host .app
│   ├── TerminalFocuser.swift        # activate + AppleScript/AX window raise
│   └── FileWatcher.swift            # DispatchSource debounced directory watcher
├── Stores/
│   └── SessionStore.swift           # @Published sessions + filter state
└── Views/
    ├── MenuBarContent.swift         # popover
    ├── FilterBar.swift              # status pills
    ├── SessionRow.swift             # list row
    └── HistoryWindow.swift          # message history window
```

## Caveats / not yet supported

- **No send-message fallback** for sessions without an active bridge. The `paperplane` button only appears when `bridgeSessionId` is set (i.e. you've run `/remote-control`). AppleScript keystroke injection was considered but deliberately skipped — too fragile.
- **Per-tab precision** only works for iTerm2 and Terminal.app. Cursor/VSCode get correct-window precision (via the IDE lock files + AX). Warp, Ghostty, WezTerm get app-level activation only.
- **Subagent transcripts** (under `<sessionId>/subagents/`) aren't aggregated in the main timeline yet — only the parent session's transcript is shown.
- **Task viewer** for `~/.claude/tasks/` isn't built yet.

## License

MIT
