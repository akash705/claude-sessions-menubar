import Foundation

enum StatusResolver {

    /// Activity window used to distinguish running from idle (seconds).
    static let activeWindow: TimeInterval = 120

    static func resolve(
        summary: TranscriptReader.Summary,
        live: LiveSessionRecord?,
        now: Date = Date()
    ) -> SessionStatus {
        let isLive = live != nil
        let recentlyActive = now.timeIntervalSince(summary.lastActivity) <= activeWindow

        if summary.recentError && !isLive {
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
        } else {
            if summary.recentError { return .error }
            return .done
        }
    }
}
