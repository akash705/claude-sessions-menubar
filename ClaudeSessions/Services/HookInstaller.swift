import Foundation

/// Manages the on-disk pieces required for Claude Code to route permission
/// prompts to our menubar app:
///   1. The bridge script at `~/.claude/menubar/permission-bridge.sh`.
///      Written/refreshed every launch so an upgraded app gets an upgraded
///      bridge for free.
///   2. The `PreToolUse` hook entry in `~/.claude/settings.json`.
///      Adds/removes this only when the user clicks Install/Uninstall, so
///      we never silently rewrite the user's settings on launch.
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

    static func isHookInstalled() -> Bool {
        // Use try? here on purpose — UI just needs the boolean, errors are
        // surfaced from install/uninstall paths instead.
        guard let settings = try? readSettingsStrict() ?? [:] else { return false }
        return findOurHookIndex(in: settings) != nil
    }

    /// Adds (or replaces) our PreToolUse hook entry. Preserves any other
    /// hook entries the user has configured. Throws rather than silently
    /// clobbering an unparseable settings.json.
    static func installHook() throws {
        var settings = try readSettingsStrict() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []

        let ourEntry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": bridgePath.path,
                    "timeout": 120
                ]
            ],
            "_source": hookMarker
        ]

        if let idx = findOurHookIndex(in: settings) {
            preToolUse[idx] = ourEntry
        } else {
            preToolUse.append(ourEntry)
        }
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstallHook() throws {
        guard var settings = try readSettingsStrict(),
              var hooks = settings["hooks"] as? [String: Any],
              var preToolUse = hooks["PreToolUse"] as? [[String: Any]],
              let idx = findOurHookIndex(in: settings) else { return }
        preToolUse.remove(at: idx)
        if preToolUse.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else {
            hooks["PreToolUse"] = preToolUse
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
    }

    // MARK: - Internals

    /// Stamped on the entry so we can find/replace/remove it later without
    /// touching hook entries the user added themselves.
    private static let hookMarker = "claude-sessions-menubar"

    private static func findOurHookIndex(in settings: [String: Any]) -> Int? {
        guard let hooks = settings["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]] else { return nil }
        return preToolUse.firstIndex { ($0["_source"] as? String) == hookMarker }
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

    private static let bridgeSource: String = """
    #!/bin/bash
    # Claude Code PreToolUse hook bridge for the Claude Sessions menubar app.
    # Auto-installed by Claude Sessions; do not edit — it gets overwritten on
    # every app launch.

    set -u

    PORT_FILE="$HOME/.claude/menubar/port"
    CURL_TIMEOUT=90

    PAYLOAD=$(cat)

    fallback() {
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\\n'
        exit 0
    }

    [[ -r "$PORT_FILE" ]] || fallback
    PORT=$(tr -d '[:space:]' < "$PORT_FILE")
    [[ -n "$PORT" ]] || fallback

    RESPONSE=$(printf '%s' "$PAYLOAD" | curl -fsS \\
        --max-time "$CURL_TIMEOUT" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "http://127.0.0.1:$PORT/permission" 2>/dev/null) || fallback

    [[ -n "$RESPONSE" ]] || fallback
    printf '%s\\n' "$RESPONSE"
    """
}
