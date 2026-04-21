# Claude Sessions — Setup

A macOS menubar app that surfaces your active Claude Code sessions, last message preview, and lets you filter by status.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later (full Xcode, not just Command Line Tools — SwiftUI `MenuBarExtra` requires the macOS SDK)

Verify Xcode is selected:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

## Option A — XcodeGen (recommended)

```sh
brew install xcodegen
cd /Users/akash/Desktop/code/personal/menubar
xcodegen generate
open ClaudeSessions.xcodeproj
```

Then ⌘R in Xcode. The menubar icon appears at the top-right of the screen.

## Option B — manual Xcode project

1. In Xcode: *File → New → Project → macOS → App*.
2. Product name `ClaudeSessions`, Interface `SwiftUI`, Language `Swift`.
3. Save the project in `/Users/akash/Desktop/code/personal/menubar`.
4. Delete the generated `ContentView.swift` and `ClaudeSessionsApp.swift` files from the project (leave the ones on disk in `ClaudeSessions/` alone).
5. Right-click the project → *Add Files to "ClaudeSessions"* → select the `ClaudeSessions/` folder, choose *Create groups*, add all `.swift` files under `Models/`, `Services/`, `Stores/`, `Views/`, and `ClaudeSessionsApp.swift`.
6. In *Target → Info*, set `LSUIElement` = YES (so no dock icon).
7. Build & run.

## Option C — compile check only (no app)

Swift Package Manager can type-check the sources but can't produce an app bundle:

```sh
cd /Users/akash/Desktop/code/personal/menubar
swift build    # type-checks all code; won't produce a runnable .app
```

## What it watches

- `~/.claude/sessions/` — one JSON per running Claude Code process; source of truth for "is the session alive".
- `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` — transcript per session; tailed for preview and activity time.

Only sessions whose transcript was modified within the last 7 days are shown.

## Status rules

| Status  | Condition |
|---------|-----------|
| running | Live PID alive AND last transcript entry is assistant within 2 min |
| pending | Live PID alive AND last entry is user message or tool_result |
| idle    | Live PID alive AND no transcript activity for 2+ min |
| done    | No live PID AND transcript mtime within 7 days |
| error   | Recent tool_result with `is_error: true` (overrides done/idle) |
