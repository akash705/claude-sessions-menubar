import Foundation
import Combine
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedStatuses: Set<SessionStatus> = Set(SessionStatus.allCases)
    @Published var lastRefresh: Date = .distantPast
    @Published var isBlinking: Bool = false
    /// Toggles every 0.5s while `isBlinking` is true. The label view binds to
    /// this directly so the icon updates even when the popover is closed.
    @Published var blinkPhase: Bool = false

    private let scanQueue = DispatchQueue(label: "SessionStore.scan", qos: .utility)
    private var watcher: FileWatcher?
    private var tickTimer: Timer?
    private var blinkToggleTimer: Timer?
    private var blinkStopTimer: Timer?

    private struct PrevState {
        let status: SessionStatus
        let awaitingPermission: Bool
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
    }

    func refresh() {
        scanQueue.async { [weak self] in
            let list = SessionScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                let needsAttention = self.detectAttentionTransition(in: list)
                self.prevStates = Dictionary(uniqueKeysWithValues: list.map {
                    ($0.id, PrevState(status: $0.status, awaitingPermission: $0.isAwaitingPermission))
                })
                self.sessions = list
                self.lastRefresh = Date()
                if needsAttention { self.startBlinking() }
            }
        }
    }

    /// Returns true when any session has just transitioned to a state that
    /// likely warrants the user's attention:
    ///   - agent stopped responding (running → pending)
    ///   - agent now waiting on permission (awaitingPermission false → true)
    ///   - error appeared (anything → error)
    ///   - session ended (active → done)
    /// First-seen sessions never trigger (we have no prior state to compare).
    private func detectAttentionTransition(in list: [Session]) -> Bool {
        let liveStates: Set<SessionStatus> = [.running, .pending, .idle]
        for s in list {
            guard let prev = prevStates[s.id] else { continue } // skip first sighting
            // Agent stopped responding mid-session
            if prev.status == .running && s.status == .pending { return true }
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
        sessions.filter { selectedStatuses.contains($0.status) }
    }

    var counts: [SessionStatus: Int] {
        var dict: [SessionStatus: Int] = [:]
        for s in sessions { dict[s.status, default: 0] += 1 }
        return dict
    }

    var activeBadgeCount: Int {
        (counts[.running] ?? 0) + (counts[.pending] ?? 0)
    }

    func session(id: String) -> Session? {
        sessions.first(where: { $0.id == id })
    }

    func toggle(_ status: SessionStatus) {
        if selectedStatuses.contains(status) {
            selectedStatuses.remove(status)
            if selectedStatuses.isEmpty { selectedStatuses = Set(SessionStatus.allCases) }
        } else {
            selectedStatuses.insert(status)
        }
    }

    func setAll() { selectedStatuses = Set(SessionStatus.allCases) }
    var allSelected: Bool { selectedStatuses.count == SessionStatus.allCases.count }
}
