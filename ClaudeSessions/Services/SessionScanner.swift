import Foundation

enum SessionScanner {

    /// Retention window: ignore transcripts older than this.
    static let recencyWindow: TimeInterval = 7 * 24 * 3600

    static func scan(now: Date = Date()) -> [Session] {
        let live = LiveSessionIndex.load()
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projects,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [Session] = []

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let projectDirName = projectDir.lastPathComponent
            let decodedProjectPath = ClaudePaths.decodeProjectDirName(projectDirName)

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(mtime) > recencyWindow { continue }

                let sessionId = file.deletingPathExtension().lastPathComponent

                guard let summary = TranscriptReader.summarize(url: file) else { continue }

                let liveRec = live[sessionId]
                let status = StatusResolver.resolve(summary: summary, live: liveRec, now: now)

                let session = Session(
                    id: sessionId,
                    projectDirName: projectDirName,
                    projectPath: decodedProjectPath,
                    cwd: liveRec?.cwd ?? decodedProjectPath,
                    transcriptPath: file,
                    pid: liveRec?.pid,
                    startedAt: liveRec?.startedAt,
                    lastActivity: summary.lastActivity,
                    lastMessagePreview: summary.lastPreview,
                    status: status,
                    pendingTool: summary.pendingTool,
                    permissionMode: summary.permissionMode,
                    bridgeSessionId: liveRec?.bridgeSessionId
                )
                sessions.append(session)
            }
        }

        sessions.sort { $0.lastActivity > $1.lastActivity }
        return sessions
    }
}
