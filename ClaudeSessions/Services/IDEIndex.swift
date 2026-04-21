import Foundation

/// Reads `~/.claude/ide/*.lock` files. Each lock represents one IDE *window*
/// that's connected to a Claude Code session. Crucially, `workspaceFolders`
/// tells us which cwd the window is rooted at — so we can pick the right
/// window when the user has multiple Cursor/VSCode instances open.
struct IDELock {
    let pid: Int
    let ideName: String
    let workspaceFolders: [String]
    let primaryWorkspace: String?
}

enum IDEIndex {
    /// Returns the IDE lock whose `workspaceFolders` matches the given cwd.
    /// Matching is: cwd == folder OR cwd is inside folder OR folder is inside cwd.
    static func lock(forCwd cwd: String) -> IDELock? {
        for lock in all() {
            for folder in lock.workspaceFolders {
                if cwd == folder { return lock }
                if cwd.hasPrefix(folder + "/") { return lock }
                if folder.hasPrefix(cwd + "/") { return lock }
            }
        }
        return nil
    }

    static func all() -> [IDELock] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: ClaudePaths.ide,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var locks: [IDELock] = []
        for url in items where url.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int
            else { continue }

            let ideName = (obj["ideName"] as? String) ?? "IDE"
            let wf = (obj["workspaceFolders"] as? [String]) ?? []
            locks.append(IDELock(
                pid: pid,
                ideName: ideName,
                workspaceFolders: wf,
                primaryWorkspace: wf.first
            ))
        }
        return locks
    }
}
