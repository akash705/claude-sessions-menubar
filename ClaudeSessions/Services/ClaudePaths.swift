import Foundation

enum ClaudePaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var projects: URL   { home.appendingPathComponent("projects") }
    static var sessions: URL   { home.appendingPathComponent("sessions") }
    static var tasks: URL      { home.appendingPathComponent("tasks") }
    static var ide: URL        { home.appendingPathComponent("ide") }

    /// Best-effort decode of a project directory name back to an absolute path.
    /// Claude Code encodes cwd by replacing "/" with "-". Real paths with dashes
    /// cannot be perfectly recovered — prefer the `cwd` inside the transcript when
    /// known; use this only for display labels.
    static func decodeProjectDirName(_ name: String) -> String {
        guard !name.isEmpty else { return name }
        // Leading "-" is the root slash.
        var s = name
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }
}
