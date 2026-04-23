import Foundation

enum TranscriptReader {

    /// Read the tail of a JSONL file, returning up to `maxLines` decoded entries
    /// in file order (oldest → newest). Reads in 8 KB backward chunks to avoid
    /// loading large transcripts fully.
    static func tail(url: URL, maxLines: Int = 50) -> [TranscriptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let chunkSize: Int = 8 * 1024
        var offset: UInt64
        do {
            try handle.seekToEnd()
            offset = try handle.offset()
        } catch { return [] }
        if offset == 0 { return [] }

        var buffer = Data()
        var lines: [String] = []

        while offset > 0 && lines.count <= maxLines {
            let readSize = UInt64(chunkSize)
            let newOffset = offset > readSize ? offset - readSize : 0
            do { try handle.seek(toOffset: newOffset) } catch { break }
            let chunkLen = Int(offset - newOffset)
            let chunk = (try? handle.read(upToCount: chunkLen)) ?? Data()
            buffer = chunk + buffer
            offset = newOffset

            // Split buffer on \n; keep the first (possibly partial) piece unless at file start.
            var pieces = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
            if offset > 0 {
                // Oldest piece is potentially truncated; hold it back for next chunk.
                let partial = pieces.removeFirst()
                buffer = partial
            } else {
                buffer = Data()
            }
            // Prepend completed lines to our collection in reverse so final order is file order.
            let strs = pieces.compactMap { String(data: $0, encoding: .utf8) }
                             .filter { !$0.isEmpty }
            lines = strs + lines
            if lines.count > maxLines * 3 {
                // Safety cap against pathological files.
                break
            }
        }

        // Trim to last N
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        return lines.compactMap { TranscriptDecoder.decode(line: $0) }
    }

    /// Read the entire transcript (streaming by line). For the history window.
    static func readAll(url: URL) -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { TranscriptDecoder.decode(line: String($0)) }
    }

    struct Summary {
        let lastActivity: Date
        let lastPreview: String
        let lastEntry: TranscriptEntry?
        let recentError: Bool
        /// If Claude has emitted a tool_use that hasn't been matched by a
        /// tool_result yet, this is populated. A live session in this state is
        /// waiting on the user to approve/deny the tool call.
        let pendingTool: PendingTool?
        /// Last-seen permission mode ("plan", "default", "acceptEdits", etc.), if any.
        let permissionMode: String?
        /// Authoritative cwd as recorded in the transcript. Preferred over the
        /// decoded project dir name, since Claude Code's "/" → "-" encoding is
        /// lossy for paths that contain dashes (e.g. "piano-practice" would
        /// decode to "piano/practice").
        let cwd: String?
    }

    struct PendingTool: Hashable {
        let name: String
        let input: String
    }

    /// Produce the summary fields used for the list view.
    static func summarize(url: URL) -> Summary? {
        let entries = tail(url: url, maxLines: 40)
        guard !entries.isEmpty else { return nil }

        let lastActivity: Date = entries.compactMap(\.timestamp).max()
            ?? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date())

        // Find latest entry that actually shows user-facing content.
        let last = entries.reversed().first { entry in
            guard entry.kind == .user || entry.kind == .assistant else { return false }
            return !entry.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? entries.last

        let preview = Self.clip(last?.previewText ?? "", maxChars: 140)
        let recentError = entries.contains(where: { $0.hasError })
        let pendingTool = computePendingTool(entries: entries)
        let permissionMode = latestPermissionMode(entries: entries)
        let cwd = latestCwd(entries: entries)

        return Summary(
            lastActivity: lastActivity,
            lastPreview: preview,
            lastEntry: last,
            recentError: recentError,
            pendingTool: pendingTool,
            permissionMode: permissionMode,
            cwd: cwd
        )
    }

    private static func latestCwd(entries: [TranscriptEntry]) -> String? {
        for e in entries.reversed() {
            guard let data = e.rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Walks the tail: collects every tool_use_id, removes those with a matching
    /// tool_result. The newest still-unmatched tool_use (if any) is the one
    /// awaiting user action.
    static func computePendingTool(entries: [TranscriptEntry]) -> PendingTool? {
        var pending: [(id: String, name: String, input: String)] = []
        for e in entries {
            for block in e.toolUseBlocks { pending.append(block) }
            let resolved = Set(e.toolResultIds)
            if !resolved.isEmpty {
                pending.removeAll { resolved.contains($0.id) }
            }
        }
        guard let last = pending.last else { return nil }
        return PendingTool(name: last.name, input: last.input)
    }

    private static func latestPermissionMode(entries: [TranscriptEntry]) -> String? {
        // permission-mode entries don't carry `message.content`; their raw line
        // contains the `permissionMode` field directly.
        for e in entries.reversed() where e.kind == .permissionMode {
            if let data = e.rawLine.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mode = obj["permissionMode"] as? String {
                return mode
            }
        }
        return nil
    }

    private static func clip(_ s: String, maxChars: Int) -> String {
        let cleaned = cleanForPreview(s)
        if cleaned.count <= maxChars { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: maxChars)
        return cleaned[..<idx] + "…"
    }

    /// Strip markdown formatting and protocol XML tags so list previews show
    /// plain readable text instead of raw syntax.
    private static func cleanForPreview(_ s: String) -> String {
        var result = s
        // Strip XML/protocol tags like <local-command-stdout>...</local-command-stdout>
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Strip markdown headers (## Title → Title)
        if let regex = try? NSRegularExpression(pattern: "^#{1,6}\\s+", options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Strip bold/italic markers
        result = result.replacingOccurrences(of: "\\*{1,3}", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "_{1,3}", with: "", options: .regularExpression)
        // Collapse whitespace / newlines
        result = result.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
