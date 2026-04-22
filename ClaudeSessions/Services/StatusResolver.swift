import Foundation

enum StatusResolver {

    /// Activity window used to distinguish running from idle (seconds).
    static let activeWindow: TimeInterval = 120

    static func resolve(
        summary: TranscriptReader.Summary,
        live: LiveSessionRecord?,
        fileMTime: Date,
        now: Date = Date()
    ) -> SessionStatus {
        let isLive = live != nil
        let recentlyActive = now.timeIntervalSince(summary.lastActivity) <= activeWindow
        // Mtime fallback: some Claude Code sessions never land a pid.json in
        // ~/.claude/sessions (older invocations, different entrypoints, or
        // versions that simply don't write it). Without this, a transcript
        // that's actively being appended to right now gets marked .done and
        // disappears behind the default Active filter — exactly the "stale
        // session shown, current session invisible" bug users hit when they
        // spawn a second Claude in the same directory.
        let mtimeRecent = now.timeIntervalSince(fileMTime) <= activeWindow

        if summary.recentError && !isLive && !mtimeRecent {
            return .error
        }

        if isLive {
            if !recentlyActive { return .idle }
            // Pending means "Claude is blocked waiting for something" — i.e.
            // an unmatched tool_use (awaiting approval or execution). Using
            // the last entry's role for this was wrong: tool_results are
            // stored as user-role entries, so a mid-cycle session would
            // briefly flip to .pending between the tool_use and Claude's
            // continuation even though work was actively happening.
            if summary.pendingTool != nil { return .pending }
            return .running
        } else if mtimeRecent {
            // Inferred live from disk activity. We don't know the pid, so
            // callers lose focus-terminal / permission-hook capabilities for
            // these sessions, but the row shows up with accurate status.
            if summary.pendingTool != nil { return .pending }
            return .running
        } else {
            if summary.recentError { return .error }
            return .done
        }
    }
}
