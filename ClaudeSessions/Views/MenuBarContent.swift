import SwiftUI
import AppKit

/// Popover shim — owns the environment-bound `openWindow` action and the
/// fixed 480×560 frame the MenuBarExtra expects. All real UI lives in
/// `MenuBarContentBody` so the floating panel can reuse it.
struct MenuBarContent: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContentBody(
            store: store,
            openHistory: { id in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history", value: id)
            },
            headerTrailing: {
                AnyView(
                    Button {
                        // Capture the popover's host window *before* the
                        // toggle so we close the popover specifically,
                        // not whatever is key after the panel appears.
                        // The floating panel is non-activating and won't
                        // become key, so this reliably targets the popover.
                        let popoverWindow = NSApp.keyWindow
                        store.toggleFloatingPanel()
                        popoverWindow?.close()
                    } label: {
                        Image(systemName: store.isFloatingPanelOpen ? "pip.exit" : "rectangle.on.rectangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(store.isFloatingPanelOpen ? "Close floating panel" : "Pop out floating panel")
                )
            }
        )
        .frame(width: 480, height: 560)
    }
}

struct MenuBarContentBody: View {
    @ObservedObject var store: SessionStore
    let openHistory: (String) -> Void
    let headerTrailing: (() -> AnyView)?

    init(
        store: SessionStore,
        openHistory: @escaping (String) -> Void,
        headerTrailing: (() -> AnyView)? = nil
    ) {
        self.store = store
        self.openHistory = openHistory
        self.headerTrailing = headerTrailing
    }

    /// Row-tap default: focus the session's terminal if it's alive, otherwise
    /// fall back to opening history — a done/stopped session has no terminal
    /// left to focus, so history is the only useful action.
    private func primaryTap(on session: Session) {
        if session.pid != nil {
            TerminalFocuser.focusTerminal(for: session)
        } else {
            openHistory(session.id)
        }
    }

    @ViewBuilder
    private func rowMenu(for session: Session) -> some View {
        if session.pid != nil {
            Button("Focus Terminal" + (session.hostAppName.map { " (\($0))" } ?? "")) {
                TerminalFocuser.focusTerminal(for: session)
            }
        }
        Button("Open History") { openHistory(session.id) }
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
            searchBar
            FilterBar(store: store)
            list
            footer
        }
        .onAppear { store.stopBlinking() }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search by project, path, message…", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkle")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
            Text("Claude Code Sessions")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing = headerTrailing {
                trailing()
            }
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No sessions match the current filters.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !pendingSessions.isEmpty {
                            sectionView(header: "Needs attention", sessions: pendingSessions, accent: true)
                        }
                        ForEach(grouped(mainItems), id: \.project) { bucket in
                            sectionView(header: bucket.project, sessions: bucket.sessions)
                        }
                        if !otherItems.isEmpty {
                            sectionView(header: "Other tabs", sessions: otherItems, accent: true)
                        }
                        Color.clear.frame(height: 6)
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
                let pending = store.pendingPermissions[session.id]
                // Wire Allow/Deny only when the in-app decision is on AND the
                // bridge is still alive. Once the card has expired (bridge
                // curl timed out, Claude Code fell back to the terminal),
                // the buttons can't reach anyone — leave them unwired so
                // SessionRow shows the "answer in terminal" variant.
                let interactive = store.showPermissionButtons && !(pending?.expired ?? false)
                SessionRow(
                    session: session,
                    pendingPermission: pending,
                    onAllow: interactive
                        ? { store.resolvePermission(sessionId: session.id, decision: .allow) }
                        : nil,
                    onDeny: interactive
                        ? { store.resolvePermission(sessionId: session.id, decision: .deny) }
                        : nil,
                    onOpenHistory: { openHistory(session.id) },
                    onFocusTerminal: { TerminalFocuser.focusTerminal(for: session) },
                    onDismiss: { store.dismissPermission(sessionId: session.id) }
                )
                .onTapGesture { primaryTap(on: session) }
                .contextMenu { rowMenu(for: session) }
            }
        } header: {
            HStack {
                Text(header)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(accent ? Color.accentColor : .secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(.bar)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.sessions.count) tracked")
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("Updated \(relativeRefresh)")
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Menu {
                Toggle("Allow/Deny in App", isOn: $store.showPermissionButtons)
                    .help("When off, permission cards are informational only — answer in your terminal.")
                Toggle("Always Open Floating Panel", isOn: $store.autoOpenFloatingPanel)
                    .help("When on, the floating panel opens automatically for every attention event. When off, it only opens for permissions if Allow/Deny in App is enabled.")
                Divider()
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
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
