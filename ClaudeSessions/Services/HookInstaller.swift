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

    /// Idempotent. Safe to call on every app launch. Throws so callers that
    /// need the bridge to actually exist (Install) can surface the failure
    /// instead of leaving a settings entry pointing at a missing script.
    static func writeBridgeScript() throws {
        try FileManager.default.createDirectory(at: menubarDir, withIntermediateDirectories: true)
        try bridgeSource.write(to: bridgePath, atomically: true, encoding: .utf8)
        // chmod +x — Foundation has no public symbolic flag, so set rwxr-xr-x.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgePath.path)
    }

    /// Best-effort refresh for the launch path, where a transient failure
    /// (e.g. home not yet mounted) shouldn't abort startup. Logs and moves on.
    static func writeBridgeScriptBestEffort() {
        do {
            try writeBridgeScript()
        } catch {
            NSLog("[ClaudeSessions] writeBridgeScript failed: \(error)")
        }
    }

    /// The bridge is truly usable only if the script exists and is executable.
    private static func bridgeScriptIsUsable() -> Bool {
        FileManager.default.isExecutableFile(atPath: bridgePath.path)
    }

    enum InstallError: Error, LocalizedError {
        case settingsUnparseable(URL)
        case settingsShapeUnexpected(String)
        var errorDescription: String? {
            switch self {
            case .settingsUnparseable(let url):
                return "Refusing to overwrite \(url.path) — file exists but is not valid JSON. Fix it manually first."
            case .settingsShapeUnexpected(let key):
                return "Refusing to modify settings.json — `\(key)` has an unexpected shape. Fix it manually first so we don't discard your data."
            }
        }
    }

    /// Presence of our PreToolUse entry is the canonical "hook installed"
    /// signal — the Stop hook rides along but isn't load-bearing on its own.
    static func isHookInstalled() -> Bool {
        guard let settings = try? readSettingsStrict() ?? [:] else { return false }
        guard ourStampedIndex(in: settings, key: "PreToolUse") != nil else { return false }
        // A stamped entry that points at a missing/non-executable bridge is a
        // broken install, not an installed one — reporting it as installed
        // would hide the breakage behind an "Uninstall" label.
        return bridgeScriptIsUsable()
    }

    /// Adds (or replaces) our PreToolUse + Stop hook entries. Preserves any
    /// other hook entries the user has configured. Throws rather than
    /// silently clobbering an unparseable settings.json.
    static func installHook() throws {
        // Write the bridge before the settings entry so we never leave a hook
        // pointing at a missing script. Throws (surfaced by the caller) on
        // failure rather than logging and continuing.
        try writeBridgeScript()

        var settings = try readSettingsStrict() ?? [:]
        var hooks = try dict(settings, "hooks") ?? [:]

        hooks["PreToolUse"] = upsert(
            list: try hookList(hooks, "PreToolUse"),
            entry: makeEntry(matcher: Self.promptingToolsMatcher, timeout: Self.preToolUseTimeout)
        )
        hooks["Stop"] = upsert(
            list: try hookList(hooks, "Stop"),
            // Stop has no matcher — it fires on every turn-end globally.
            entry: makeEntry(matcher: nil, timeout: Self.stopTimeout)
        )
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// Coerce `settings[key]` to an object, or throw if present-but-wrong-shape.
    /// A missing key returns nil; a key holding a non-object (e.g. an array or
    /// string) throws instead of being silently replaced with our own data.
    private static func dict(_ settings: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let value = settings[key] else { return nil }
        guard let obj = value as? [String: Any] else {
            throw InstallError.settingsShapeUnexpected(key)
        }
        return obj
    }

    /// Coerce `hooks[key]` to a hook list, or throw if present-but-wrong-shape.
    private static func hookList(_ hooks: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let value = hooks[key] else { return [] }
        guard let list = value as? [[String: Any]] else {
            throw InstallError.settingsShapeUnexpected("hooks.\(key)")
        }
        return list
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
    /// mutate state, run arbitrary code, reach the network, or ask the user
    /// something — the ones Claude Code itself would prompt on — plus every
    /// MCP tool (`mcp__server__tool`). Read/Grep/Glob/LS are deliberately
    /// excluded so the bridge never even runs for silent auto-allowed reads
    /// (an explicit list, not `*`, keeps them off the hot path). `Task` is
    /// included because spawning a subagent fans out to more tool calls; a
    /// brand-new tool we don't list simply falls back to Claude Code's own
    /// prompt, which is the safe default.
    private static let promptingToolsMatcher =
        "Bash|Write|Edit|MultiEdit|NotebookEdit|WebFetch|WebSearch|Task|ExitPlanMode|AskUserQuestion|mcp__.*"

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
    private static func readSettingsStrict(at url: URL = settingsPath) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Treat any read failure as "no settings yet". The most common
            // case is ENOENT; permission errors will surface again on write.
            return nil
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InstallError.settingsUnparseable(url)
        }
        guard let obj = parsed as? [String: Any] else {
            throw InstallError.settingsUnparseable(url)
        }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL = settingsPath) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        // Skip the write when nothing changed. `upgradeInstalledHookIfNeeded`
        // runs on every launch; without this it would rewrite settings.json
        // each time — bumping mtime and reformatting the user's file (our
        // .sortedKeys/.prettyPrinted output) even when the hook is identical.
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - "Always Allow" rule persistence

    /// The narrowest, matcher-compatible allow rule for a request, or nil when
    /// no *specific* rule can be derived — in which case "Always Allow" should
    /// be disabled rather than persist an over-broad grant. Deliberately
    /// conservative:
    ///   • MCP tool → the exact `mcp__server__tool` name (a bare-name match).
    ///   • WebFetch → `WebFetch(domain:<host>)` scoped to the URL's host.
    ///   • Edit/Write/MultiEdit → the exact `file_path` for the actual tool.
    ///   • Bash → nil (a first-word prefix like `Bash(git *)` would allow
    ///     `git push --force`; too risky to auto-derive).
    ///   • Everything else → nil (only a blanket `ToolName` could be written).
    /// Every returned rule round-trips through `PermissionRuleMatcher` so the
    /// same call auto-resolves next time instead of re-prompting.
    static func allowRule(for pending: PendingPermission) -> String? {
        switch pending.kind {
        case .mcp:
            return pending.toolName
        case .webFetch:
            guard let urlString = pending.url,
                  let host = URLComponents(string: urlString)?.host else { return nil }
            return "WebFetch(domain:\(host))"
        case .edit, .multiEdit, .write:
            guard let path = pending.filePath else { return nil }
            return "\(pending.toolName)(\(path))"
        case .bash, .ask, .generic:
            return nil
        }
    }

    /// Appends an allow rule to the project-local `settings.local.json` (the
    /// conventional machine-specific location), or user-global local settings
    /// when there's no project directory. Project-local scoping keeps a grant
    /// derived from one repo out of unrelated sessions, and avoids reformatting
    /// the user's hand-maintained global `settings.json`. Dedups so repeated
    /// clicks don't grow the list. Throws on unparseable target JSON.
    static func appendAllowRule(_ rule: String, cwd: String?) throws {
        let target = allowRuleTargetPath(cwd: cwd)
        var settings = try readSettingsStrict(at: target) ?? [:]
        var permissions = try dict(settings, "permissions") ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        guard !allow.contains(rule) else { return }
        allow.append(rule)
        permissions["allow"] = allow
        settings["permissions"] = permissions
        try writeSettings(settings, to: target)
    }

    private static func allowRuleTargetPath(cwd: String?) -> URL {
        if let cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(".claude/settings.local.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.local.json")
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
    TOKEN_FILE="$HOME/.claude/menubar/token"
    # Authoritative human answer window. Must stay BELOW the server's request
    # expiry (~32s) and Claude Code's hook `timeout` (120s) so curl is always
    # the first to give up — that way the server sees the socket close and
    # clears the now-dead card instead of two layers racing to time out.
    PERMISSION_TIMEOUT=30
    STOP_TIMEOUT=5
    # Caps only the TCP connect, separately from the answer wait above. When
    # the app isn't running we want the bridge to fall back to Claude's own
    # prompt fast instead of pinning the user for the full answer window. A
    # dead port usually refuses instantly; this bounds the rarer "connects but
    # stalls" case (e.g. a stale port now held by another process). Loopback
    # connects to a live app are sub-millisecond, so 2s is ample headroom.
    CONNECT_TIMEOUT=2

    PAYLOAD=$(cat)

    # Shared secret the server publishes next to the port; proves we're talking
    # to our app and not a process that reused the old ephemeral port. Empty if
    # absent — the server then rejects us and we fall back to Claude's prompt.
    # `cat ... | tr` rather than `tr < file` so a missing token file is silent
    # — with input redirection the "No such file" error leaks to stderr before
    # `2>/dev/null` applies. Empty TOKEN just means the server rejects us and we
    # fall back, which is the correct behavior when the app hasn't published one.
    TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')

    EVENT=$(printf '%s' "$PAYLOAD" \
        | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/')

    permission_fallback() {
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\n'
        exit 0
    }

    # A PreToolUse payload always carries a top-level "tool_name"; a Stop
    # payload never does. Requiring tool_name to be ABSENT before taking the
    # Stop path means a tool_input that happens to embed the literal
    # "hook_event_name":"Stop" (e.g. a Write/Edit of this very file, or a Bash
    # command echoing it) can't be misread as a fire-and-forget Stop — which
    # would silently skip the in-app permission prompt for that call.
    if [ "$EVENT" = "Stop" ] && ! printf '%s' "$PAYLOAD" | grep -q '"tool_name"[[:space:]]*:'; then
        # Best-effort fire-and-forget; always succeed so we never block
        # Claude from ending a turn if our app is down.
        if [ -r "$PORT_FILE" ]; then
            PORT=$(tr -d '[:space:]' < "$PORT_FILE")
            if [ -n "$PORT" ]; then
                printf '%s' "$PAYLOAD" | curl -fsS \
                    --connect-timeout "$CONNECT_TIMEOUT" \
                    --max-time "$STOP_TIMEOUT" \
                    -H "Content-Type: application/json" \
                    -H "X-Menubar-Token: $TOKEN" \
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
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$PERMISSION_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "X-Menubar-Token: $TOKEN" \
        --data-binary @- \
        "http://127.0.0.1:$PORT/permission" 2>/dev/null) || permission_fallback

    [ -n "$RESPONSE" ] || permission_fallback
    printf '%s\n' "$RESPONSE"
    """#
}
