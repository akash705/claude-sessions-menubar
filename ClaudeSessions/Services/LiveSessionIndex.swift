import Foundation

struct LiveSessionRecord {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Date?
    let bridgeSessionId: String?
    /// The user-assigned session name, if any. Claude Code stores a
    /// user-set name wrapped in quotes (`"my task"`) and an auto-generated
    /// one bare (`project-6f`); we only surface the former, quotes stripped.
    let userName: String?
}

enum LiveSessionIndex {

    /// Scans `~/.claude/sessions/*.json` and returns a map keyed by `sessionId`,
    /// filtered to records whose PID is currently alive. Stale files (dead PIDs)
    /// are ignored (but not deleted — we only read).
    static func load() -> [String: LiveSessionRecord] {
        let dir = ClaudePaths.sessions
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var out: [String: LiveSessionRecord] = [:]
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  let sid = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String
            else { continue }

            guard ProcessLiveness.isAlive(pid: pid) else { continue }

            var startedAt: Date? = nil
            if let ms = obj["startedAt"] as? Double {
                startedAt = Date(timeIntervalSince1970: ms / 1000.0)
            }
            let bridgeSid = obj["bridgeSessionId"] as? String
            let userName = Self.userAssignedName(obj["name"] as? String)
            out[sid] = LiveSessionRecord(
                pid: pid, sessionId: sid, cwd: cwd,
                startedAt: startedAt, bridgeSessionId: bridgeSid,
                userName: userName
            )
        }
        return out
    }

    /// Returns the name only when it's a user-set one — Claude Code wraps
    /// those in double quotes (`"my task"`) and leaves auto-generated names
    /// (`project-6f`) bare. Strips the wrapping quotes; nil if bare or empty.
    private static func userAssignedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }
}
