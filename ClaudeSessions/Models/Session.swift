import Foundation

enum SessionStatus: String, CaseIterable, Codable, Hashable {
    case running, pending, idle, done, error

    var label: String {
        switch self {
        case .running: return "Running"
        case .pending: return "Pending"
        case .idle:    return "Idle"
        case .done:    return "Done"
        case .error:   return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "bolt.fill"
        case .pending: return "clock.fill"
        case .idle:    return "moon.zzz.fill"
        case .done:    return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }
}

struct Session: Identifiable, Hashable {
    let id: String                  // sessionId (UUID string)
    let projectDirName: String      // encoded dir under ~/.claude/projects
    let projectPath: String         // best-effort decoded cwd (from dir name)
    let cwd: String                 // authoritative cwd from transcript or sessions/<pid>.json
    let transcriptPath: URL
    let pid: Int?
    let startedAt: Date?
    let lastActivity: Date
    let lastMessagePreview: String
    let status: SessionStatus
    let pendingTool: TranscriptReader.PendingTool?
    let permissionMode: String?
    let bridgeSessionId: String?

    var bridgeURL: URL? {
        guard let b = bridgeSessionId, !b.isEmpty else { return nil }
        return URL(string: "https://claude.ai/code/\(b)")
    }

    /// True when Claude has requested a tool use that the user hasn't responded to yet,
    /// and the session is currently alive. That's the "awaiting permission" state.
    var isAwaitingPermission: Bool {
        pendingTool != nil && pid != nil && (status == .pending || status == .running)
    }

    var projectLabel: String {
        (cwd.split(separator: "/").last.map(String.init))
            ?? (projectPath.split(separator: "/").last.map(String.init))
            ?? projectDirName
    }
}
