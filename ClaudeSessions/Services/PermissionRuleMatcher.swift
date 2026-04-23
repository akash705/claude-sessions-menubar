import Foundation

/// Consults `~/.claude/settings.json` `permissions.allow` / `permissions.deny`
/// so pre-approved tool calls don't pop a menubar card. Our PreToolUse hook
/// fires before Claude Code's own permission flow, so without this step
/// every allow-rule the user configured gets bypassed.
///
/// Scope is deliberately narrow: we support the two rule forms that cover
/// the vast majority of real configs —
///   • `ToolName`              → any call to that tool
///   • `Bash(prefix:*)`        → Bash with command starting with `prefix`
/// Anything else (path globs, URL patterns, nested specs) falls through to
/// the UI. A partial matcher that handles the common case beats a complete
/// matcher shipped next week.
enum PermissionRuleMatcher {

    enum Decision { case allow, deny }

    private static let userSettingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// `nil` → no matching rule; the caller should prompt the user as usual.
    static func decision(forTool toolName: String, input: [String: Any]) -> Decision? {
        let rules = loadRules()
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
        let allow: [String]
        let deny: [String]
    }

    /// Read on every request — settings.json is small and the user may edit
    /// it between calls. Cheap compared to the cost of a wrong answer.
    private static func loadRules() -> Rules {
        guard let data = try? Data(contentsOf: userSettingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = obj["permissions"] as? [String: Any]
        else { return Rules(allow: [], deny: []) }
        let allow = permissions["allow"] as? [String] ?? []
        let deny = permissions["deny"] as? [String] ?? []
        return Rules(allow: allow, deny: deny)
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
        guard tool == "Bash", pattern.hasSuffix(":*") else { return false }
        let prefix = String(pattern.dropLast(2))
        guard let command = input["command"] as? String else { return false }
        // Match `prefix` exactly, or `prefix ` followed by args — avoids
        // matching `sed-something` when the rule said `sed:*`.
        return command == prefix || command.hasPrefix(prefix + " ")
    }
}
