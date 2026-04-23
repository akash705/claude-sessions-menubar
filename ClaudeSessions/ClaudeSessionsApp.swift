import SwiftUI

@main
struct ClaudeSessionsApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            // The label appears immediately at launch; the popover's onAppear
            // doesn't fire until first click. MenuBarLabel's own .task starts
            // the store, which ensures the permission server is up before any
            // tool prompt arrives.
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "history", for: String.self) { $sessionId in
            if let id = sessionId {
                HistoryWindow(sessionId: id, store: store)
            } else {
                Text("No session selected.")
                    .frame(minWidth: 400, minHeight: 200)
            }
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            if store.isBlinking {
                Image(systemName: store.blinkPhase ? "exclamationmark.circle.fill" : "sparkle")
                    .foregroundStyle(store.blinkPhase ? Color.orange : .primary)
            } else {
                Image(systemName: "sparkle")
            }
            if store.activeBadgeCount > 0 {
                Text("\(store.activeBadgeCount)")
                    .font(.caption2.monospacedDigit())
            }
        }
        .task {
            // Capture `openWindow` while we're inside a `Scene`, so the
            // floating panel (hosted outside any Scene) can still route
            // "Open History" through the same WindowGroup the popover uses.
            FloatingPanelController.shared.setOpenHistory { id in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history", value: id)
            }
            store.start()
            FloatingPanelController.shared.restoreOnLaunchIfNeeded(store: store)
        }
    }
}
