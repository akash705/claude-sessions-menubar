import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    private func openHistory(for sessionId: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "history", value: sessionId)
    }

    @ViewBuilder
    private func rowMenu(for session: Session) -> some View {
        Button("Open History") { openHistory(for: session.id) }
        if session.pid != nil {
            let host = TerminalFocuser.hostAppName(for: session)
            Button("Focus Terminal" + (host.map { " (\($0))" } ?? "")) {
                TerminalFocuser.focusTerminal(for: session)
            }
        }
        if let url = session.bridgeURL {
            Button("Send Message (open bridge)") {
                NSWorkspace.shared.open(url)
            }
        }
        Divider()
        Button("Reveal Transcript in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.transcriptPath])
        }
        Button("Copy Session ID") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(session.id, forType: .string)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            FilterBar(store: store)
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .onAppear { store.stopBlinking() }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search by project, path, message…", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("Claude Code Sessions")
                .font(.headline)
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var list: some View {
        let items = store.filteredSessions
        return Group {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text("No sessions match the current filters.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(grouped(items), id: \.project) { bucket in
                            Section {
                                ForEach(bucket.sessions) { session in
                                    SessionRow(session: session)
                                        .onTapGesture { openHistory(for: session.id) }
                                        .contextMenu { rowMenu(for: session) }
                                    Divider().padding(.leading, 34)
                                }
                            } header: {
                                HStack {
                                    Text(bucket.project)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .background(.bar)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(store.sessions.count) tracked")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("Updated \(relativeRefresh)")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var relativeRefresh: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: store.lastRefresh, relativeTo: Date())
    }

    private struct ProjectBucket {
        let project: String
        let sessions: [Session]
    }

    private func grouped(_ items: [Session]) -> [ProjectBucket] {
        var order: [String] = []
        var buckets: [String: [Session]] = [:]
        for s in items {
            let key = s.projectLabel
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }
        return order.map { ProjectBucket(project: $0, sessions: buckets[$0] ?? []) }
    }
}
