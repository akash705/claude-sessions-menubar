import SwiftUI

@main
struct ClaudeSessionsApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(store: store)
                .onAppear { store.start() }
        } label: {
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

    var body: some View {
        HStack(spacing: 3) {
            if store.isBlinking {
                Image(systemName: store.blinkPhase ? "checkmark.circle.fill" : "sparkle")
                    .foregroundStyle(store.blinkPhase ? Color.green : .primary)
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
