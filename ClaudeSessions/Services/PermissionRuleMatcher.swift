import Foundation

/// Consults Claude Code's `permissions.allow` / `permissions.deny` rules so
/// pre-approved tool calls don't pop a menubar card. Our PreToolUse hook
/// fires before Claude Code's own permission flow, so without this step
/// every allow-rule the user configured gets bypassed.
///
/// Files merged (mirrors Claude Code's own precedence — deny wins across all):
///   • `~/.claude/settings.json`
///   • `~/.claude/settings.local.json`
///   • `<cwd>/.claude/settings.json`
///   • `<cwd>/.claude/settings.local.json`
///
/// Rule forms supported:
///   • `ToolName`               → any call to that tool
///   • `Bash(prefix:*)`         → Bash command starting with `prefix`
///   • `Bash(prefix *)`         → same, the trailing-space-glob form people write by hand
/// Anything else (path globs, URL patterns, nested specs) falls through to
/// the UI. A partial matcher that handles the common case beats a complete
/// matcher shipped next week.
enum PermissionRuleMatcher {

    enum Decision { case allow, deny }

    /// `nil` → no matching rule; the caller should prompt the user as usual.
    /// `cwd` should be the working directory from the hook payload so we can
    /// pick up project-local settings; passing `nil` only consults user-global.
    static func decision(forTool toolName: String, input: [String: Any], cwd: String?) -> Decision? {
        let rules = loadRules(cwd: cwd)
        // Deny wins over allow so a narrow deny can carve out a broad allow.
        if rules.deny.contains(where: { matches($0, tool: toolName, input: input) }) {
            return .deny
        }
        if rules.allow.contains(where: { matches($0, tool: toolName, input: input) }) {
            return .allow
        }
        return nil
    }

    // MARK: - Internals

    private struct Rules {
        var allow: [String]
        var deny: [String]
    }

    /// Read on every request — settings files are small and the user may edit
    /// them between calls. Cheap compared to the cost of a wrong answer.
    private static func loadRules(cwd: String?) -> Rules {
        var paths: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent(".claude/settings.json"))
        paths.append(home.appendingPathComponent(".claude/settings.local.json"))
        if let cwd, !cwd.isEmpty {
            let project = URL(fileURLWithPath: cwd, isDirectory: true)
            paths.append(project.appendingPathComponent(".claude/settings.json"))
            paths.append(project.appendingPathComponent(".claude/settings.local.json"))
        }

        var merged = Rules(allow: [], deny: [])
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let permissions = obj["permissions"] as? [String: Any]
            else { continue }
            if let allow = permissions["allow"] as? [String] { merged.allow.append(contentsOf: allow) }
            if let deny = permissions["deny"] as? [String] { merged.deny.append(contentsOf: deny) }
        }
        return merged
    }

    private static func matches(_ rule: String, tool: String, input: [String: Any]) -> Bool {
        guard let openParen = rule.firstIndex(of: "(") else {
            // Bare `ToolName` — matches any call to that tool.
            return rule == tool
        }
        let ruleName = String(rule[..<openParen])
        guard ruleName == tool, rule.last == ")" else { return false }
        let pattern = String(rule[rule.index(after: openParen)..<rule.index(before: rule.endIndex)])
        // Only Bash prefix patterns are supported; other tools' parenthesized
        // forms (paths, URLs, etc.) fall through to the UI.
        guard tool == "Bash" else { return false }
        let prefix: String
        if pattern.hasSuffix(":*") {
            prefix = String(pattern.dropLast(2))
        } else if pattern.hasSuffix(" *") {
            // Trailing-space glob form (e.g. `Bash(xcodegen generate *)`).
            prefix = String(pattern.dropLast(2))
        } else if pattern == "*" {
            prefix = ""
        } else {
            return false
        }
        guard let command = input["command"] as? String else { return false }
        if prefix.isEmpty { return true }
        // Match `prefix` exactly, or `prefix ` followed by args — avoids
        // matching `sed-something` when the rule said `sed:*`.
        return command == prefix || command.hasPrefix(prefix + " ")
    }
}
