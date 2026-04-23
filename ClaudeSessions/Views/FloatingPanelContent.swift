import SwiftUI
import AppKit

/// Root view hosted inside the full-size floating NSPanel. Fixed size
/// matching the panel's content rect — giving SwiftUI an explicit frame
/// prevents it from negotiating window content-size extrema with AppKit
/// (the crash path).
struct FloatingPanelContent: View {
    @ObservedObject var store: SessionStore
    let openHistory: (String) -> Void
    let onMinimize: () -> Void
    let onClose: () -> Void

    init(
        store: SessionStore,
        openHistory: @escaping (String) -> Void,
        onMinimize: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.openHistory = openHistory
        self.onMinimize = onMinimize
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            FloatingTitleBar(onMinimize: onMinimize, onClose: onClose)
            MenuBarContentBody(
                store: store,
                openHistory: openHistory,
                headerTrailing: nil
            )
        }
        .frame(
            width: FloatingPanelController.mainSize.width,
            height: FloatingPanelController.mainSize.height
        )
        // Panel is borderless + transparent; content paints its own
        // window-background fill and clips to a rounded rect so the shadow
        // follows the rounded shape.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Traffic-light-style titlebar. Empty space also doubles as the drag
/// handle via `NSPanel.isMovableByWindowBackground`.
private struct FloatingTitleBar: View {
    let onMinimize: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TitleBarButton(system: "xmark", help: "Close floating panel", color: Color(nsColor: .systemRed), action: onClose)
            TitleBarButton(system: "minus", help: "Collapse to pill", color: Color(nsColor: .systemYellow), action: onMinimize)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct TitleBarButton: View {
    let system: String
    let help: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                if hovering {
                    Image(systemName: system)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.7))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help(help)
    }
}

/// Shows a pointing-hand cursor while the pointer is over the view.
/// Uses the cursor stack so it layers cleanly over any surrounding cursor
/// (e.g. text cursor inside a search field) — push on enter, pop on exit.
extension View {
    func pointerCursor() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
