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
///   • `ToolName*` (bare glob)  → any tool whose name starts with the prefix
///                                (e.g. `mcp__memory__*` for a whole MCP server)
///   • `Bash(prefix:*)`         → Bash command starting with `prefix`
///   • `Bash(prefix *)`         → same, the trailing-space-glob form people write by hand
///   • `WebFetch(domain:host)`  → WebFetch whose URL host is `host` (or `*.host`)
///   • `Edit(/path/**)` etc.    → file tool whose `file_path` matches the glob
/// Anything else (unrecognized parenthesized specs) falls through to the UI.
///
/// `matches` is used for BOTH allow and deny, so support is symmetric by
/// construction — there is no way for an allow form to be parsed more broadly
/// than the corresponding deny form. Globs are kept narrower-or-equal to
/// Claude Code's own interpretation: when in doubt we return false and let
/// the UI decide (safe) rather than risk auto-allowing more than intended.
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
            // A missing file is expected (not every scope has settings); a
            // file that exists but won't parse is NOT — silently skipping it
            // drops the user's allow AND deny rules (a deny meant to block a
            // dangerous tool would stop being enforced with no warning). Log
            // the corrupt path so the failure is visible.
            guard let data = try? Data(contentsOf: path) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[ClaudeSessions] PermissionRuleMatcher: \(path.path) is not valid JSON — its allow/deny rules are being ignored")
                continue
            }
            guard let permissions = obj["permissions"] as? [String: Any] else { continue }
            if let allow = permissions["allow"] as? [String] { merged.allow.append(contentsOf: allow) }
            if let deny = permissions["deny"] as? [String] { merged.deny.append(contentsOf: deny) }
        }
        return merged
    }

    private static func matches(_ rule: String, tool: String, input: [String: Any]) -> Bool {
        guard let openParen = rule.firstIndex(of: "(") else {
            // Bare `ToolName`, or a trailing-`*` tool-name glob such as
            // `mcp__server__*` that matches every tool on that MCP server.
            if rule.hasSuffix("*") {
                return tool.hasPrefix(String(rule.dropLast()))
            }
            return rule == tool
        }
        let ruleName = String(rule[..<openParen])
        guard ruleName == tool, rule.last == ")" else { return false }
        let pattern = String(rule[rule.index(after: openParen)..<rule.index(before: rule.endIndex)])

        switch tool {
        case "Bash":
            return matchesBash(pattern: pattern, input: input)
        case "WebFetch":
            return matchesWebFetch(pattern: pattern, input: input)
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read", "Glob":
            return matchesPath(pattern: pattern, input: input)
        default:
            // Unrecognized parenthesized form → fall through to the UI.
            return false
        }
    }

    private static func matchesBash(pattern: String, input: [String: Any]) -> Bool {
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

    private static func matchesWebFetch(pattern: String, input: [String: Any]) -> Bool {
        guard pattern.hasPrefix("domain:"),
              let urlString = input["url"] as? String,
              let host = URLComponents(string: urlString)?.host?.lowercased()
        else { return false }
        let domain = String(pattern.dropFirst("domain:".count)).lowercased()
        if domain.hasPrefix("*.") {
            let base = String(domain.dropFirst(2))
            return host == base || host.hasSuffix("." + base)
        }
        return host == domain
    }

    private static func matchesPath(pattern: String, input: [String: Any]) -> Bool {
        guard let path = input["file_path"] as? String else { return false }
        return pathGlobMatches(pattern: pattern, path: path)
    }

    /// Conservative gitignore-ish glob: `**` matches across path separators,
    /// `*` matches within a single segment, everything else is literal. A
    /// pattern with no glob characters must match the path exactly. Kept
    /// deliberately narrow — an unrecognized construct simply won't match.
    private static func pathGlobMatches(pattern: String, path: String) -> Bool {
        if !pattern.contains("*") { return pattern == path }
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    continue
                }
                regex += "[^/]*"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
