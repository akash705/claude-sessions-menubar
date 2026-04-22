import SwiftUI

@main
struct ClaudeSessionsApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            // The label appears immediately at launch; the popover's onAppear
            // doesn't fire until first click. Starting here ensures the
            // permission server is up before any tool prompt arrives.
            MenuBarLabel(store: store)
                .task { store.start() }
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
    }
}
