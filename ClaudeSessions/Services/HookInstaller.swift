import Foundation

/// Manages the on-disk pieces required for Claude Code to route permission
/// prompts and turn-end signals to our menubar app:
///   1. The bridge script at `~/.claude/menubar/permission-bridge.sh`.
///      Written/refreshed every launch so an upgraded app gets an upgraded
///      bridge for free.
///   2. Two hook entries in `~/.claude/settings.json`:
///        • `PreToolUse` — routes permission prompts to our menubar.
///        • `Stop` — pings our server when an agent finishes a turn so the
///          floating panel can auto-surface.
///      Added/removed only when the user clicks Install/Uninstall so we
///      never silently rewrite the user's settings on launch.
enum HookInstaller {

    private static let menubarDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/menubar", isDirectory: true)
    private static var bridgePath: URL { menubarDir.appendingPathComponent("permission-bridge.sh") }
    private static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Idempotent. Safe to call on every app launch.
    static func writeBridgeScript() {
        do {
            try FileManager.default.createDirectory(at: menubarDir, withIntermediateDirectories: true)
            try bridgeSource.write(to: bridgePath, atomically: true, encoding: .utf8)
            // chmod +x — Foundation has no public symbolic flag, so set rwxr-xr-x.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgePath.path)
        } catch {
            NSLog("[ClaudeSessions] writeBridgeScript failed: \(error)")
        }
    }

    enum InstallError: Error, LocalizedError {
        case settingsUnparseable(URL)
        var errorDescription: String? {
            switch self {
            case .settingsUnparseable(let url):
                return "Refusing to overwrite \(url.path) — file exists but is not valid JSON. Fix it manually first."
            }
        }
    }

    /// Presence of our PreToolUse entry is the canonical "hook installed"
    /// signal — the Stop hook rides along but isn't load-bearing on its own.
    static func isHookInstalled() -> Bool {
        guard let settings = try? readSettingsStrict() ?? [:] else { return false }
        return ourStampedIndex(in: settings, key: "PreToolUse") != nil
    }

    /// Adds (or replaces) our PreToolUse + Stop hook entries. Preserves any
    /// other hook entries the user has configured. Throws rather than
    /// silently clobbering an unparseable settings.json.
    static func installHook() throws {
        var settings = try readSettingsStrict() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        hooks["PreToolUse"] = upsert(
            list: hooks["PreToolUse"] as? [[String: Any]] ?? [],
            entry: makeEntry(matcher: Self.promptingToolsMatcher, timeout: Self.preToolUseTimeout)
        )
        hooks["Stop"] = upsert(
            list: hooks["Stop"] as? [[String: Any]] ?? [],
            // Stop has no matcher — it fires on every turn-end globally.
            entry: makeEntry(matcher: nil, timeout: Self.stopTimeout)
        )
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// If our hook entries are already installed, rewrite them to the
    /// current format — so matcher/timeout/bridge-path changes ship with
    /// app updates without the user having to manually Uninstall → Install.
    /// Best-effort; errors swallowed.
    static func upgradeInstalledHookIfNeeded() {
        guard isHookInstalled() else { return }
        try? installHook()
    }

    static func uninstallHook() throws {
        guard var settings = try readSettingsStrict() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in ["PreToolUse", "Stop"] {
            guard var list = hooks[key] as? [[String: Any]] else { continue }
            list.removeAll { ($0["_source"] as? String) == hookMarker }
            if list.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = list
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
    }

    // MARK: - Internals

    /// Stamped on every entry we own so we can find/replace/remove it later
    /// without touching hook entries the user added themselves.
    private static let hookMarker = "claude-sessions-menubar"

    /// Regex matched against Claude Code tool names. Covers the tools that
    /// mutate state or run arbitrary code — the ones Claude Code itself
    /// would prompt on. Read/Grep/Glob/LS are deliberately excluded so the
    /// menubar isn't spammed with auto-allowed calls. `Task` is included
    /// because spawning a subagent fans out to more tool calls.
    private static let promptingToolsMatcher = "Bash|Write|Edit|MultiEdit|NotebookEdit|WebFetch|Task"

    private static let preToolUseTimeout = 120
    /// Stop is fire-and-forget; the bridge returns `{}` immediately without
    /// waiting on the server, so this timeout just caps the HTTP round-trip.
    private static let stopTimeout = 30

    private static func makeEntry(matcher: String?, timeout: Int) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": bridgePath.path,
                    "timeout": timeout
                ]
            ],
            "_source": hookMarker
        ]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    /// Reap orphan unstamped entries that also point at our bridge (legacy
    /// installs that didn't write `_source`) then upsert our stamped entry.
    /// Doing reap-before-upsert keeps exactly one copy of ours in the list.
    private static func upsert(list: [[String: Any]], entry: [String: Any]) -> [[String: Any]] {
        var out = list
        let bridge = bridgePath.path
        out.removeAll { e in
            guard (e["_source"] as? String) != hookMarker else { return false }
            return entryPointsAtOurBridge(e, bridgePath: bridge)
        }
        if let idx = out.firstIndex(where: { ($0["_source"] as? String) == hookMarker }) {
            out[idx] = entry
        } else {
            out.append(entry)
        }
        return out
    }

    private static func ourStampedIndex(in settings: [String: Any], key: String) -> Int? {
        guard let hooks = settings["hooks"] as? [String: Any],
              let list = hooks[key] as? [[String: Any]] else { return nil }
        return list.firstIndex { ($0["_source"] as? String) == hookMarker }
    }

    /// True if this entry's `hooks` contains a command invocation pointing
    /// at our bridge script. Used to reap unstamped orphans.
    private static func entryPointsAtOurBridge(_ entry: [String: Any], bridgePath: String) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String) == bridgePath }
    }

    /// Returns nil if the file doesn't exist (fine — we'll create it).
    /// Throws `InstallError.settingsUnparseable` if the file exists but
    /// isn't valid JSON, so we never silently overwrite the user's data.
    private static func readSettingsStrict() throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: settingsPath)
        } catch {
            // Treat any read failure as "no settings yet". The most common
            // case is ENOENT; permission errors will surface again on write.
            return nil
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InstallError.settingsUnparseable(settingsPath)
        }
        guard let obj = parsed as? [String: Any] else {
            throw InstallError.settingsUnparseable(settingsPath)
        }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsPath, options: .atomic)
    }

    /// Bridge script. Dispatches by `hook_event_name` in the payload:
    ///   • Stop           → POST /stop, immediately print `{}` and exit.
    ///                      Fire-and-forget: never blocks the agent.
    ///   • PreToolUse     → POST /permission, block on server reply.
    ///                      Falls back to `permissionDecision:"ask"` if the
    ///                      server is unreachable so Claude Code drops back
    ///                      to its own terminal prompt.
    ///
    /// `grep -o` + `sed` is used instead of `jq` to avoid adding a runtime
    /// dependency; `[[:space:]]*` handles both `":X"` and `": X"` spacing
    /// variants the serializer might produce.
    private static let bridgeSource: String = #"""
    #!/bin/bash
    # Claude Code hook bridge for the Claude Sessions menubar app.
    # Auto-installed by Claude Sessions; do not edit — it gets overwritten on
    # every app launch.

    set -u

    PORT_FILE="$HOME/.claude/menubar/port"
    PERMISSION_TIMEOUT=90
    STOP_TIMEOUT=5

    PAYLOAD=$(cat)

    EVENT=$(printf '%s' "$PAYLOAD" \
        | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/')

    permission_fallback() {
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\n'
        exit 0
    }

    if [ "$EVENT" = "Stop" ]; then
        # Best-effort fire-and-forget; always succeed so we never block
        # Claude from ending a turn if our app is down.
        if [ -r "$PORT_FILE" ]; then
            PORT=$(tr -d '[:space:]' < "$PORT_FILE")
            if [ -n "$PORT" ]; then
                printf '%s' "$PAYLOAD" | curl -fsS \
                    --max-time "$STOP_TIMEOUT" \
                    -H "Content-Type: application/json" \
                    --data-binary @- \
                    "http://127.0.0.1:$PORT/stop" >/dev/null 2>&1 || true
            fi
        fi
        printf '{}\n'
        exit 0
    fi

    # Default path: PreToolUse (permission request).
    [ -r "$PORT_FILE" ] || permission_fallback
    PORT=$(tr -d '[:space:]' < "$PORT_FILE")
    [ -n "$PORT" ] || permission_fallback

    RESPONSE=$(printf '%s' "$PAYLOAD" | curl -fsS \
        --max-time "$PERMISSION_TIMEOUT" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "http://127.0.0.1:$PORT/permission" 2>/dev/null) || permission_fallback

    [ -n "$RESPONSE" ] || permission_fallback
    printf '%s\n' "$RESPONSE"
    """#
}
