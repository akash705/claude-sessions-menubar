# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS **menubar app** (SwiftUI `MenuBarExtra`, `LSUIElement`) that is a **read-only observer** of Claude Code's on-disk state under `~/.claude/`, plus a loopback HTTP server that receives PreToolUse/Stop hook POSTs. It never modifies transcripts or talks to the Claude API. Read `README.md` for the full feature/behavior spec — the hook pipeline, status rules, and floating-panel surface rules are documented there and are the source of truth for intended behavior.

## Build & run

The Xcode project is **generated** from `project.yml` via XcodeGen and is git-ignored (`*.xcodeproj` is in `.gitignore`) — regenerate it after cloning or after changing `project.yml`:

```sh
brew install xcodegen
xcodegen generate            # (re)creates ClaudeSessions.xcodeproj
open ClaudeSessions.xcodeproj # then ⌘R in Xcode
```

- **Full Xcode 15+ required** — Command Line Tools alone can't build `MenuBarExtra`. macOS 14+ deployment target.
- **Type-check without Xcode**: `swift build`. `Package.swift` is a *compile-check harness only* — it type-checks all sources but cannot produce a runnable `.app`. Use it for fast validation of Swift changes.
- **Release artifact**: `scripts/build-release.sh <version>` → runs `xcodebuild` and packages `dist/ClaudeSessions-<version>.{zip,dmg}`. Locally signed (`-`), not notarized.
- There is **no test target and no linter** configured. Validate changes with `swift build` (type-check) and a manual run in Xcode.

## Architecture

Data flows one direction: on-disk files → scanners → `SessionStore` (`@Published`) → SwiftUI views. Layers under `ClaudeSessions/`:

- **`Services/`** — all the on-disk reading and OS integration. `SessionScanner` walks `~/.claude/projects/` and assembles `[Session]`; it composes `LiveSessionIndex` (running PIDs from `sessions/*.json`), `TranscriptReader` (backward-chunked JSONL tail + full read), `StatusResolver` (the status-rule table), `ProcessLiveness`/`ProcessTree` (PID checks + libproc ancestor walk to find the host `.app`), and `IDEIndex` (`ide/*.lock` → workspace window). `TerminalFocuser` raises the hosting window (AppleScript for iTerm2/Terminal.app by TTY; Accessibility API for IDE windows).
- **`Stores/SessionStore.swift`** — the single `@MainActor ObservableObject` and hub. Owns the published session list, filters, blink state, floating-panel flags, pending permissions, and user prefs (persisted via `UserDefaults`). Drives refresh via `FileWatcher` (DispatchSource) + a polling tick, computes status transitions against `prevStates` to decide when to blink/surface.
- **`Services/PermissionServer.swift`** — loopback HTTP server. `POST /permission` (PreToolUse) **blocks** until the user answers or timeout; `POST /stop` (turn-end) is fire-and-forget. Binds an ephemeral port on `127.0.0.1` and publishes it to `~/.claude/menubar/port`. `PermissionRuleMatcher` consults `settings.json` allow/deny to auto-resolve; `SessionStore` holds `pendingResolvers` that unblock the HTTP request when a card is clicked.
- **`Services/HookInstaller.swift`** — writes the bridge shell script (**embedded in this Swift file, not checked into the repo**) to `~/.claude/menubar/permission-bridge.sh` and adds `_source`-stamped hook entries to `~/.claude/settings.json`. Re-stamps on every launch so matcher/timeout changes ship without a manual reinstall. Refuses to write if `settings.json` isn't valid JSON.
- **`Services/FloatingPanelController.swift`** — `NSPanel` lifecycle for the always-on-top panel (main 500×500 and compact pill). Hosted **outside any SwiftUI Scene**, so it can't use `@Environment(\.openWindow)` directly — `ClaudeSessionsApp` captures `openWindow` and hands it to the controller via `setOpenHistory`.
- **`Views/`** — `MenuBarContent` holds the shared body reused by both the popover and the floating panel; `SessionRow` renders both list rows and permission cards.
- **`Models/`** — `Session` (+ `SessionStatus` enum), `TranscriptEntry` (JSONL line + content-block decoder), `PendingPermission` (in-flight permission + hook response shape).

## Conventions & gotchas

- `SessionStore` is `@MainActor`; scanning runs on `scanQueue` (utility QoS) and hops back to main to publish. Keep UI-touching state on the main actor.
- **`MenuBarExtra` popover cannot be opened programmatically** (SwiftUI limitation) — that's why attention events force-open the floating panel instead. Don't assume you can pop the menubar popover from code.
- The bridge script lives only in `HookInstaller.swift` as a Swift string literal — edit it there, not on disk. `~/.claude/menubar/` is runtime state, never committed.
- All `~/.claude/*` path construction goes through `ClaudePaths.swift`.
- Prefs use `UserDefaults` with a `didSet` write-through pattern; `showPermissionButtons` distinguishes "unset" from "explicitly false" via `object(forKey:)`.
- The app is entitled/sandboxed (`ClaudeSessions.entitlements`) and hardened-runtime on. No outbound network — the server is loopback only.
