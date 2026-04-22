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
    let receivedAt: Date

    static func == (lhs: PendingPermission, rhs: PendingPermission) -> Bool {
        lhs.id == rhs.id
    }

    /// Human-readable single-line summary for the row UI: "Bash: rm -rf /tmp/foo".
    var summary: String {
        let detail = previewDetail() ?? ""
        return detail.isEmpty ? toolName : "\(toolName): \(detail)"
    }

    private func previewDetail() -> String? {
        // The most useful preview field varies per tool. These are the
        // canonical fields we know about — fall through to a generic
        // first-string-value heuristic for unknown tools.
        if let cmd = toolInput["command"] as? String { return trimmed(cmd) }
        if let path = toolInput["file_path"] as? String { return trimmed(path) }
        if let url = toolInput["url"] as? String { return trimmed(url) }
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

    /// The exact stdout shape Claude Code's PreToolUse hook expects.
    var hookResponseJSON: [String: Any] {
        [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": rawValue
            ]
        ]
    }
}
