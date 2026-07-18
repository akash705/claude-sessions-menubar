import Foundation

/// One permission request currently held by the menubar app, originating
/// from Claude Code's PreToolUse hook. The HTTP request stays open until
/// the user clicks Allow/Deny — `resolver` is the continuation that
/// shapes the hook's response back to Claude Code.
struct PendingPermission: Identifiable, Equatable {
    let id: UUID
    let sessionId: String
    let toolName: String
    /// Raw `tool_input` JSON object (already decoded into Foundation types).
    let toolInput: [String: Any]
    /// Working directory from the hook payload, if present — used to scope an
    /// "Always Allow" rule to the project's local settings.
    let cwd: String?
    let receivedAt: Date
    /// Set when the bridge connection has gone away (curl --max-time fired and
    /// Claude Code has fallen back to its own terminal prompt). The card stays
    /// visible as a hint to "answer in terminal" but its Allow/Deny buttons
    /// would no longer reach anyone, so the UI hides them.
    var expired: Bool = false

    static func == (lhs: PendingPermission, rhs: PendingPermission) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Tool classification

    /// How the card should render this request. Derived from `toolName` so
    /// the view can switch on a small, exhaustive set rather than string-match
    /// tool names in the UI layer.
    enum Kind {
        case bash
        case edit
        case multiEdit
        case write
        case webFetch
        case ask       // AskUserQuestion — informational only (the hook can't answer it)
        case mcp       // any mcp__server__tool
        case generic
    }

    var kind: Kind {
        if toolName.hasPrefix("mcp__") { return .mcp }
        switch toolName {
        case "Bash":           return .bash
        case "Edit":           return .edit
        case "MultiEdit":      return .multiEdit
        case "Write":          return .write
        case "WebFetch":       return .webFetch
        case "AskUserQuestion": return .ask
        default:               return .generic
        }
    }

    // MARK: - Typed accessors over `toolInput`

    var command: String? { toolInput["command"] as? String }
    var filePath: String? { toolInput["file_path"] as? String }
    var oldString: String? { toolInput["old_string"] as? String }
    var newString: String? { toolInput["new_string"] as? String }
    var content: String? { toolInput["content"] as? String }
    var url: String? { toolInput["url"] as? String }
    var prompt: String? { toolInput["prompt"] as? String }
    var question: String? { toolInput["question"] as? String }

    /// MultiEdit carries `edits: [{old_string, new_string, replace_all?}]`.
    /// Returns them as (old, new) pairs, skipping malformed entries.
    var edits: [(old: String, new: String)] {
        guard let raw = toolInput["edits"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let old = entry["old_string"] as? String,
                  let new = entry["new_string"] as? String else { return nil }
            return (old, new)
        }
    }

    /// Total edit entries in the payload, including any `edits` dropped as
    /// malformed. A consent card can compare this against `edits.count` to
    /// warn when the previewed diff is silently incomplete.
    var rawEditCount: Int { (toolInput["edits"] as? [[String: Any]])?.count ?? 0 }

    /// For `mcp__server__tool`, splits out the server and tool components.
    /// `("server", "tool")` — either may be empty if the name is malformed.
    var mcpComponents: (server: String, tool: String)? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let parts = toolName.dropFirst("mcp__".count).components(separatedBy: "__")
        let server = parts.first ?? ""
        let tool = parts.count > 1 ? parts[1...].joined(separator: "__") : ""
        return (server, tool)
    }

    /// Local image files referenced by this request, for inline thumbnails.
    /// Deliberately narrow: only the known path-bearing fields (`file_path`,
    /// `path`) are considered, and each must be an ABSOLUTE, EXISTING file
    /// with an image extension. This avoids false positives from arbitrary
    /// strings (e.g. `rm foo.png`, a Grep pattern, or an image URL).
    var imagePaths: [String] {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
        let candidates = ["file_path", "path"].compactMap { toolInput[$0] as? String }
        return candidates.filter { path in
            guard path.hasPrefix("/"),
                  imageExtensions.contains((path as NSString).pathExtension.lowercased())
            else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    // MARK: - Summary (compact fallback)

    /// Human-readable single-line summary for the row UI: "Bash: rm -rf /tmp/foo".
    var summary: String {
        let detail = previewDetail() ?? ""
        return detail.isEmpty ? toolName : "\(toolName): \(detail)"
    }

    private func previewDetail() -> String? {
        // The most useful preview field varies per tool. These are the
        // canonical fields we know about — fall through to a generic
        // first-string-value heuristic for unknown tools.
        if let cmd = command { return trimmed(cmd) }
        if let path = filePath { return trimmed(path) }
        if let url = url { return trimmed(url) }
        if let pattern = toolInput["pattern"] as? String { return trimmed(pattern) }
        for (_, v) in toolInput {
            if let s = v as? String { return trimmed(s) }
        }
        return nil
    }

    private func trimmed(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }
}

enum PermissionDecision: String {
    case allow, deny
    /// Hands the prompt back to Claude Code's built-in terminal UI. We use
    /// this on app shutdown so a quit menubar doesn't silently deny a tool
    /// the user might have wanted to run.
    case ask

    /// The exact stdout shape Claude Code's PreToolUse hook expects. An
    /// optional `reason` populates `permissionDecisionReason`, which Claude
    /// Code feeds back to the model (so a denial can carry a "why").
    func hookResponseJSON(reason: String? = nil) -> [String: Any] {
        var output: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": rawValue
        ]
        if let reason, !reason.isEmpty {
            output["permissionDecisionReason"] = reason
        }
        return ["hookSpecificOutput": output]
    }
}
