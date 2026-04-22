import Foundation
import Combine
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedStatuses: Set<SessionStatus> = Set(SessionStatus.allCases)
    @Published var lastRefresh: Date = .distantPast
    @Published var isBlinking: Bool = false

    private let scanQueue = DispatchQueue(label: "SessionStore.scan", qos: .utility)
    private var watcher: FileWatcher?
    private var tickTimer: Timer?
    private var blinkTimer: Timer?
    private var prevStatuses: [String: SessionStatus] = [:]

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

        let w = FileWatcher(debounce: 0.5) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        w.start(urls: all)
        self.watcher = w

        // Periodic tick to catch PID-death transitions and idle transitions
        // (filesystem is silent in those cases).
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        tickTimer?.invalidate()
        tickTimer = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    func refresh() {
        scanQueue.async { [weak self] in
            let list = SessionScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                let activeSet: Set<SessionStatus> = [.running, .pending]
                let justFinished = list.contains { s in
                    activeSet.contains(self.prevStatuses[s.id] ?? s.status) && s.status == .done
                }
                self.prevStatuses = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.status) })
                self.sessions = list
                self.lastRefresh = Date()
                if justFinished { self.startBlinking() }
            }
        }
    }

    func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    private func startBlinking() {
        isBlinking = true
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
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
