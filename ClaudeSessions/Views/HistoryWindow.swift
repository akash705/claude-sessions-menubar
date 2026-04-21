import SwiftUI
import AppKit

struct HistoryWindow: View {
    let sessionId: String
    @ObservedObject var store: SessionStore
    @State private var entries: [TranscriptEntry] = []
    @State private var watcher: FileWatcher?
    @State private var pollTimer: Timer?
    @State private var lastMTime: Date = .distantPast
    @State private var lastSize: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session = store.session(id: sessionId), session.isAwaitingPermission, let tool = session.pendingTool {
                PermissionBanner(tool: tool, session: session)
                Divider()
            }
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var header: some View {
        let session = store.session(id: sessionId)
        return HStack(alignment: .center, spacing: 10) {
            if let s = session {
                StatusDot(status: s.status)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.projectLabel).font(.headline)
                    Text(s.cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let mode = s.permissionMode {
                    Text("mode: \(mode)")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                if let pid = s.pid {
                    Text("pid \(pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if s.pid != nil {
                    Button {
                        TerminalFocuser.focusTerminal(for: s)
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Focus terminal\(TerminalFocuser.hostAppName(for: s).map { " (\($0))" } ?? "")")
                }
                if let url = s.bridgeURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .help("Send message via Claude bridge")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([s.transcriptPath])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal transcript in Finder")
            } else {
                Text("Session \(sessionId.prefix(8))…")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(12)
    }

    private var content: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                    Text("No messages yet.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(sortedEntries) { entry in
                                EntryView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: entries.count) { _, _ in
                        if let first = sortedEntries.first {
                            withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }
        }
    }

    private var sortedEntries: [TranscriptEntry] {
        // Newest first. Stable fallback to file order when timestamps tie/missing.
        let indexed = entries.enumerated().map { (idx, e) in (idx, e) }
        let sorted = indexed.sorted { lhs, rhs in
            let lt = lhs.1.timestamp ?? .distantPast
            let rt = rhs.1.timestamp ?? .distantPast
            if lt != rt { return lt > rt }
            return lhs.0 > rhs.0
        }
        return sorted.map { $0.1 }
    }

    private func start() {
        guard let s = store.session(id: sessionId) else { return }
        let url = s.transcriptPath
        reload(url: url, force: true)

        // FS event path — fires on append, rename, delete.
        let w = FileWatcher(debounce: 0.15) {
            Task { @MainActor in
                // Re-watch in case the fd got invalidated by atomic rename.
                self.rewatch(url: url)
                self.reload(url: url, force: false)
            }
        }
        w.start(urls: [url, url.deletingLastPathComponent()])
        self.watcher = w

        // Polling fallback — catches cases where FS events don't fire reliably
        // (e.g. writes from another volume or certain editors). 500 ms is
        // comfortable for streaming output without being wasteful.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in self.reload(url: url, force: false) }
        }
    }

    private func stop() {
        watcher?.stop(); watcher = nil
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func rewatch(url: URL) {
        watcher?.stop()
        let w = FileWatcher(debounce: 0.15) {
            Task { @MainActor in self.reload(url: url, force: false) }
        }
        w.start(urls: [url, url.deletingLastPathComponent()])
        self.watcher = w
    }

    private func reload(url: URL, force: Bool) {
        // Cheap change detection: skip re-parse unless mtime or size moved.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let size = UInt64((attrs?[.size] as? NSNumber)?.uint64Value ?? 0)
        if !force && mtime == lastMTime && size == lastSize { return }
        lastMTime = mtime
        lastSize = size

        let fresh = TranscriptReader.readAll(url: url)
        self.entries = fresh
    }
}

private struct PermissionBanner: View {
    let tool: TranscriptReader.PendingTool
    let session: Session
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Awaiting your permission")
                    .font(.headline)
                    .foregroundStyle(Color.orange)
                Text("Claude wants to use **\(tool.name)**. Approve or deny in the terminal running this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !tool.input.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(tool.input)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if session.pid != nil {
                        Button {
                            TerminalFocuser.focusTerminal(for: session)
                        } label: {
                            Label("Focus terminal", systemImage: "terminal")
                        }
                    }
                    if let url = session.bridgeURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open bridge", systemImage: "paperplane")
                        }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
    }
}

private struct EntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                roleBadge
                if let ts = entry.timestamp {
                    Text(ts.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .padding(10)
        .background(bgColor)
        .cornerRadius(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var roleBadge: some View {
        let (text, color) = roleChip
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var roleChip: (String, Color) {
        switch entry.kind {
        case .user:
            if entry.blocks.contains(where: { if case .toolResult = $0 { return true } else { return false } }) {
                return ("tool_result", .purple)
            }
            return ("user", .blue)
        case .assistant: return ("assistant", .green)
        case .system:    return ("system", .gray)
        case .attachment: return ("meta", .gray)
        case .fileHistorySnapshot: return ("snapshot", .gray)
        case .permissionMode: return ("perm", .gray)
        case .unknown: return ("?", .gray)
        }
    }

    private var bgColor: Color {
        switch entry.kind {
        case .assistant: return Color.green.opacity(0.06)
        case .user:      return Color.blue.opacity(0.06)
        default:         return Color.gray.opacity(0.08)
        }
    }

    @ViewBuilder
    private func blockView(_ block: TranscriptEntry.Block) -> some View {
        switch block {
        case .text(let s):
            Text(s)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .toolUse(_, let name, let input):
            VStack(alignment: .leading, spacing: 2) {
                Text("→ \(name)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                Text(input)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
            }
        case .toolResult(_, let s, let isError):
            VStack(alignment: .leading, spacing: 2) {
                Text(isError ? "tool_result (error)" : "tool_result")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isError ? .red : .purple)
                Text(s)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineLimit(20)
            }
        case .thinking(let s):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text("thinking")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.purple)
                Text(s)
                    .font(.callout.italic())
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08))
                    .overlay(
                        Rectangle()
                            .fill(Color.purple.opacity(0.5))
                            .frame(width: 2),
                        alignment: .leading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        case .other(let t):
            Text("[\(t)]").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
