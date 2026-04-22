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
    @State private var blinkOn = true
    @State private var blinkTimer: Timer?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.isBlinking && !blinkOn ? "checkmark.circle.fill" : "sparkle")
                .foregroundStyle(store.isBlinking ? (blinkOn ? .primary : Color.green) : .primary)
            if store.activeBadgeCount > 0 {
                Text("\(store.activeBadgeCount)")
                    .font(.caption2.monospacedDigit())
            }
        }
        .onChange(of: store.isBlinking) { _, blinking in
            if blinking {
                blinkOn = true
                blinkTimer?.invalidate()
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    blinkOn.toggle()
                }
            } else {
                blinkTimer?.invalidate()
                blinkTimer = nil
                blinkOn = true
            }
        }
    }
}
