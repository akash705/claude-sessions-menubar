import Foundation
import Combine
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedStatuses: Set<SessionStatus> = [.running, .pending, .idle]

    /// Statuses grouped under the single "Active" filter pill — all three
    /// share a live PID, so users almost always want them together.
    static let activeGroup: Set<SessionStatus> = [.running, .pending, .idle]
    @Published var searchText: String = ""
    @Published var lastRefresh: Date = .distantPast
    @Published var isBlinking: Bool = false
    /// Max age (hours) for `.done` sessions to remain visible. Other statuses
    /// are unaffected — they're either still alive or actively erroring.
    @Published var doneMaxAgeHours: Int = {
        let stored = UserDefaults.standard.integer(forKey: "doneMaxAgeHours")
        return stored > 0 ? stored : 24
    }() {
        didSet { UserDefaults.standard.set(doneMaxAgeHours, forKey: "doneMaxAgeHours") }
    }
    /// Toggles every 0.5s while `isBlinking` is true. The label view binds to
    /// this directly so the icon updates even when the popover is closed.
    @Published var blinkPhase: Bool = false
    /// Whether the always-on-top floating panel is currently visible. The
    /// FloatingPanelController writes this back on window-close so the
    /// menubar toggle icon stays in sync.
    @Published var isFloatingPanelOpen: Bool = UserDefaults.standard.bool(forKey: "floatingPanelOpen") {
        didSet { UserDefaults.standard.set(isFloatingPanelOpen, forKey: "floatingPanelOpen") }
    }
    /// Which face of the floating panel is shown when open — full 500x500
    /// content or the compact pill. Persisted so it survives relaunch.
    @Published var isFloatingPanelCompact: Bool = UserDefaults.standard.bool(forKey: "floatingPanelCompact") {
        didSet { UserDefaults.standard.set(isFloatingPanelCompact, forKey: "floatingPanelCompact") }
    }
    /// If true, permission cards show Allow/Deny and the decision happens
    /// in-app. If false, the hook answers `ask` immediately so Claude's
    /// terminal prompt fires — the card stays as an informational notice
    /// and self-dismisses after a short TTL. Defaults true.
    @Published var showPermissionButtons: Bool = {
        // `object(forKey:)` so we can distinguish "unset" (first launch —
        // default true) from "explicitly false".
        if let v = UserDefaults.standard.object(forKey: "showPermissionButtons") as? Bool { return v }
        return true
    }() {
        didSet { UserDefaults.standard.set(showPermissionButtons, forKey: "showPermissionButtons") }
    }
    /// Permission requests held by the bridge hook, keyed by sessionId.
    /// Populated when the bridge POSTs to PermissionServer; cleared when the
    /// user clicks Allow/Deny (and the HTTP response goes back).
    @Published private(set) var pendingPermissions: [String: PendingPermission] = [:]

    private let scanQueue = DispatchQueue(label: "SessionStore.scan", qos: .utility)
    private var watcher: FileWatcher?
    private var tickTimer: Timer?
    private var blinkToggleTimer: Timer?
    private var blinkStopTimer: Timer?
    private var permissionServer: PermissionServer?
    /// Resolves the HTTP request blocked on the bridge — keyed by pending id.
    private var pendingResolvers: [UUID: (PermissionDecision) -> Void] = [:]

    private struct PrevState {
        let status: SessionStatus
        let awaitingPermission: Bool
        let lastActivity: Date
    }
    private var prevStates: [String: PrevState] = [:]

    func start() {
        refresh()
        // Watch the two directories that change on session activity.
        let watchURLs: [URL] = [
            ClaudePaths.sessions,
            ClaudePaths.projects
        ]
        // Also watch each project subdirectory so we catch transcript writes.
        var all = watchURLs
        if let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: ClaudePaths.projects,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            all.append(contentsOf: projectDirs.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            })
        }

        let w = FileWatcher(debounce: 0.2) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        w.start(urls: all)
        self.watcher = w

        // Periodic tick to catch PID-death transitions and idle transitions
        // (filesystem is silent in those cases).
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        startPermissionServer()
    }

    private func startPermissionServer() {
        // Refresh the bridge script first — keeps the on-disk script in sync
        // with whatever ships in this build of the app.
        HookInstaller.writeBridgeScript()
        // Same idea for the settings.json entry itself: if the user already
        // installed the hook, re-stamp it so format changes (e.g. added
        // `matcher`) roll out on upgrade without a manual reinstall.
        HookInstaller.upgradeInstalledHookIfNeeded()

        let server = PermissionServer(
            handler: { [weak self] pending, resolve in
                guard let self else { resolve(.deny); return }
                self.pendingPermissions[pending.sessionId] = pending
                self.startBlinking()
                // Bring the main panel forward so the user doesn't have to
                // hunt for the card — the prompt would otherwise sit silent
                // in the closed popover. Non-activating, so focus stays put.
                FloatingPanelController.shared.surfaceMainForAttention(store: self)
                if self.showPermissionButtons {
                    // Interactive mode: park the resolver and wait for the
                    // user's click.
                    self.pendingResolvers[pending.id] = resolve
                } else {
                    // Informational mode: hand the decision back to Claude's
                    // terminal by responding `ask`; the card stays just long
                    // enough for the user to notice and then self-dismisses.
                    resolve(.ask)
                    self.scheduleInformationalDismissal(pendingId: pending.id)
                }
            },
            onCancel: { [weak self] pendingId in
                self?.dropPendingPermission(pendingId: pendingId)
            },
            onStop: { [weak self] _ in
                // Claude just finished a turn. Surface the main panel +
                // start the blink so the user sees the reply without
                // tabbing back to the terminal.
                guard let self else { return }
                self.startBlinking()
                FloatingPanelController.shared.surfaceMainForAttention(store: self)
            }
        )
        do {
            try server.start()
            permissionServer = server
        } catch {
            NSLog("[ClaudeSessions] PermissionServer failed to start: \(error)")
        }
    }

    func resolvePermission(sessionId: String, decision: PermissionDecision) {
        guard let pending = pendingPermissions[sessionId],
              let resolve = pendingResolvers.removeValue(forKey: pending.id) else { return }
        pendingPermissions.removeValue(forKey: sessionId)
        resolve(decision)
    }

    /// Dismisses an informational card. Used by the X button on cards
    /// rendered when `showPermissionButtons == false` — there's no
    /// resolver to call (we already responded `ask` to the hook) so this
    /// just removes the UI entry.
    func dismissPermission(sessionId: String) {
        pendingPermissions.removeValue(forKey: sessionId)
    }

    /// Drops the informational card after a short TTL. The user has
    /// usually answered in the terminal well before this fires; if not,
    /// the row quietly goes away rather than getting pinned forever.
    private func scheduleInformationalDismissal(pendingId: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            self?.dropPendingPermission(pendingId: pendingId)
        }
    }

    /// Called by PermissionServer when the bridge connection drops before
    /// the user answered. We just clean up — the bridge has already told
    /// Claude Code to fall back to the built-in prompt.
    fileprivate func dropPendingPermission(pendingId: UUID) {
        pendingResolvers.removeValue(forKey: pendingId)
        if let sessionId = pendingPermissions.first(where: { $0.value.id == pendingId })?.key {
            pendingPermissions.removeValue(forKey: sessionId)
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        tickTimer?.invalidate()
        tickTimer = nil
        blinkToggleTimer?.invalidate()
        blinkToggleTimer = nil
        blinkStopTimer?.invalidate()
        blinkStopTimer = nil
        permissionServer?.stop()
        permissionServer = nil
        // Anyone still waiting on us must be unblocked, or the hook hangs
        // until the 600s Claude Code timeout. Hand control back to the
        // built-in prompt rather than silently allowing or denying.
        for (_, resolve) in pendingResolvers { resolve(.ask) }
        pendingResolvers.removeAll()
        pendingPermissions.removeAll()
    }

    func refresh() {
        scanQueue.async { [weak self] in
            let list = SessionScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                let needsAttention = self.detectAttentionTransition(in: list)
                let shouldSurface = self.detectSurfaceTransition(in: list)
                self.prevStates = Dictionary(uniqueKeysWithValues: list.map {
                    ($0.id, PrevState(
                        status: $0.status,
                        awaitingPermission: $0.isAwaitingPermission,
                        lastActivity: $0.lastActivity
                    ))
                })
                self.sessions = list
                self.lastRefresh = Date()
                // Blink fires broadly (incl. mid-stream writes) — it's the
                // lightweight signal. Surface is narrower: only
                // error/session-ended here. Permission-arrival and
                // turn-end are driven by PermissionServer's callbacks, not
                // this JSONL-activity heuristic.
                if needsAttention { self.startBlinking() }
                if shouldSurface {
                    FloatingPanelController.shared.surfaceMainForAttention(store: self)
                }
            }
        }
    }

    /// Narrow signal for auto-surfacing the main panel from `refresh()`.
    /// Deliberately excludes the `lastActivity`-advanced branch (which is
    /// what the Stop hook now covers) and the awaitingPermission branch
    /// (PermissionServer handles it directly).
    private func detectSurfaceTransition(in list: [Session]) -> Bool {
        let liveStates: Set<SessionStatus> = [.running, .pending, .idle]
        for s in list {
            guard let prev = prevStates[s.id] else { continue }
            if prev.status != .error && s.status == .error { return true }
            if liveStates.contains(prev.status) && s.status == .done { return true }
        }
        return false
    }

    /// Returns true when any session has just transitioned to a state that
    /// likely warrants the user's attention:
    ///   - agent finished a reply turn (new assistant entry landed AND no pending tool)
    ///   - agent now waiting on permission (awaitingPermission false → true)
    ///   - error appeared (anything → error)
    ///   - session ended (active → done)
    /// First-seen sessions never trigger (we have no prior state to compare).
    private func detectAttentionTransition(in list: [Session]) -> Bool {
        let liveStates: Set<SessionStatus> = [.running, .pending, .idle]
        for s in list {
            guard let prev = prevStates[s.id] else { continue } // skip first sighting
            // Agent finished a turn: lastActivity advanced AND last entry is an
            // assistant message (status .running by definition) AND no pending
            // tool_use. This is the same moment Claude Code's stop hook fires.
            if s.lastActivity > prev.lastActivity
                && s.status == .running
                && s.pendingTool == nil { return true }
            // Just started waiting on the user for permission
            if !prev.awaitingPermission && s.isAwaitingPermission { return true }
            // Error newly surfaced
            if prev.status != .error && s.status == .error { return true }
            // Session ended
            if liveStates.contains(prev.status) && s.status == .done { return true }
        }
        return false
    }

    func stopBlinking() {
        blinkToggleTimer?.invalidate(); blinkToggleTimer = nil
        blinkStopTimer?.invalidate(); blinkStopTimer = nil
        isBlinking = false
        blinkPhase = false
    }

    private func startBlinking() {
        isBlinking = true
        blinkPhase = false
        blinkToggleTimer?.invalidate()
        blinkToggleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.blinkPhase.toggle() }
        }
        blinkStopTimer?.invalidate()
        blinkStopTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopBlinking() }
        }
    }

    // MARK: - Derived views

    var filteredSessions: [Session] {
        sessions.filter { selectedStatuses.contains($0.status) && passesAgeFilter($0) && matchesSearch($0) }
    }

    /// Sessions outside the current filter that match the search text. Empty
    /// when no search is active — search is what makes other tabs visible.
    var otherTabSearchResults: [Session] {
        let needle = trimmedNeedle
        guard !needle.isEmpty else { return [] }
        return sessions.filter { !selectedStatuses.contains($0.status) && passesAgeFilter($0) && matchesSearch($0) }
    }

    private func passesAgeFilter(_ s: Session, now: Date = Date()) -> Bool {
        guard s.status == .done else { return true }
        return now.timeIntervalSince(s.lastActivity) <= Double(doneMaxAgeHours) * 3600
    }

    private var trimmedNeedle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesSearch(_ s: Session) -> Bool {
        let needle = trimmedNeedle
        if needle.isEmpty { return true }
        if s.projectLabel.lowercased().contains(needle) { return true }
        if s.cwd.lowercased().contains(needle) { return true }
        if s.lastMessagePreview.lowercased().contains(needle) { return true }
        if s.id.lowercased().contains(needle) { return true }
        return false
    }

    var counts: [SessionStatus: Int] {
        var dict: [SessionStatus: Int] = [:]
        for s in sessions where passesAgeFilter(s) { dict[s.status, default: 0] += 1 }
        return dict
    }

    var activeBadgeCount: Int {
        (counts[.running] ?? 0) + (counts[.pending] ?? 0)
    }

    func session(id: String) -> Session? {
        sessions.first(where: { $0.id == id })
    }

    func toggle(_ status: SessionStatus) {
        // If everything is currently selected, treat the click as "narrow to
        // just this one" rather than a multi-select removal.
        if allSelected {
            selectedStatuses = [status]
            return
        }
        if selectedStatuses.contains(status) {
            selectedStatuses.remove(status)
            if selectedStatuses.isEmpty { selectedStatuses = Set(SessionStatus.allCases) }
        } else {
            selectedStatuses.insert(status)
        }
    }

    func setAll() { selectedStatuses = Set(SessionStatus.allCases) }
    var allSelected: Bool { selectedStatuses.count == SessionStatus.allCases.count }

    var activeGroupSelected: Bool {
        Self.activeGroup.isSubset(of: selectedStatuses)
    }

    /// Toggles Running, Pending, and Idle together. If `allSelected`, narrows
    /// to just the active group — mirrors `toggle(_:)`'s "narrow-on-first-click"
    /// behavior so the user isn't forced to toggle everything else off manually.
    func toggleActiveGroup() {
        if allSelected {
            selectedStatuses = Self.activeGroup
            return
        }
        if activeGroupSelected {
            selectedStatuses.subtract(Self.activeGroup)
            if selectedStatuses.isEmpty { selectedStatuses = Set(SessionStatus.allCases) }
        } else {
            selectedStatuses.formUnion(Self.activeGroup)
        }
    }

    var activeGroupCount: Int {
        Self.activeGroup.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    /// Session most recently active among running/pending — what the compact
    /// pill headlines when multiple are live.
    var mostRecentActiveSession: Session? {
        sessions
            .filter { $0.status == .running || $0.status == .pending }
            .max(by: { $0.lastActivity < $1.lastActivity })
    }

    func toggleFloatingPanel() {
        FloatingPanelController.shared.toggle(store: self)
    }
}
