import Foundation
import Combine
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedStatuses: Set<SessionStatus> = Set(SessionStatus.allCases)
    @Published var lastRefresh: Date = .distantPast

    private let scanQueue = DispatchQueue(label: "SessionStore.scan", qos: .utility)
    private var watcher: FileWatcher?
    private var tickTimer: Timer?

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
    }

    func refresh() {
        scanQueue.async { [weak self] in
            let list = SessionScanner.scan()
            DispatchQueue.main.async {
                self?.sessions = list
                self?.lastRefresh = Date()
            }
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
