import Foundation

struct LiveSessionRecord {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Date?
    let bridgeSessionId: String?
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
            out[sid] = LiveSessionRecord(
                pid: pid, sessionId: sid, cwd: cwd,
                startedAt: startedAt, bridgeSessionId: bridgeSid
            )
        }
        return out
    }
}
