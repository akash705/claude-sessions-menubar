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
            // Live + recent. Distinguish running vs pending by last entry role.
            if let last = summary.lastEntry {
                if last.endsWithUserOrToolResult { return .pending }
                if last.endsWithAssistantMessage { return .running }
            }
            return .running
        } else {
            if summary.recentError { return .error }
            return .done
        }
    }
}
