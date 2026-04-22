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
            Button("Focus Terminal" + (session.hostAppName.map { " (\($0))" } ?? "")) {
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
        let others = store.otherTabSearchResults
        // Pending permission rows surface regardless of the current filter
        // — otherwise a request on a hidden session would silently time out.
        let pendingSessions = store.sessions.filter { store.pendingPermissions[$0.id] != nil }
        let pendingIds = Set(pendingSessions.map(\.id))
        let mainItems = items.filter { !pendingIds.contains($0.id) }
        let otherItems = others.filter { !pendingIds.contains($0.id) }
        return Group {
            if pendingSessions.isEmpty && mainItems.isEmpty && otherItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text("No sessions match the current filters.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !pendingSessions.isEmpty {
                            sectionView(header: "Needs attention", sessions: pendingSessions, accent: true)
                        }
                        ForEach(grouped(mainItems), id: \.project) { bucket in
                            sectionView(header: bucket.project, sessions: bucket.sessions)
                        }
                        if !otherItems.isEmpty {
                            sectionView(header: "Other tabs", sessions: otherItems, accent: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionView(header: String, sessions: [Session], accent: Bool = false) -> some View {
        Section {
            ForEach(sessions) { session in
                SessionRow(
                    session: session,
                    pendingPermission: store.pendingPermissions[session.id],
                    onAllow: { store.resolvePermission(sessionId: session.id, decision: .allow) },
                    onDeny: { store.resolvePermission(sessionId: session.id, decision: .deny) }
                )
                .onTapGesture { openHistory(for: session.id) }
                .contextMenu { rowMenu(for: session) }
                Divider().padding(.leading, 34)
            }
        } header: {
            HStack {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent ? Color.accentColor : .secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .background(.bar)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.sessions.count) tracked")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("Updated \(relativeRefresh)")
                .font(.caption2).foregroundStyle(.secondary)
            Menu {
                if HookInstaller.isHookInstalled() {
                    Button("Uninstall Permission Hook") {
                        runHookAction("Uninstall Permission Hook") { try HookInstaller.uninstallHook() }
                    }
                } else {
                    Button("Install Permission Hook") {
                        runHookAction("Install Permission Hook") { try HookInstaller.installHook() }
                    }
                }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Surfaces hook install/uninstall errors (e.g. unparseable settings.json)
    /// instead of swallowing them — without this the gear menu would just
    /// silently no-op and leave the user mystified.
    private func runHookAction(_ title: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            let alert = NSAlert()
            alert.messageText = title + " failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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
