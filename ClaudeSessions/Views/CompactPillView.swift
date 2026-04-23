import SwiftUI

/// Zoom-style compact pill: active count + pending badge + headline project
/// + expand chevron. Hosted in its own fixed-size NSPanel (separate from
/// the main 500x500 panel) so "collapse to pill" is a hide-one / show-other
/// operation rather than a window resize — avoiding the SwiftUI
/// updateConstraints loop that single-panel resizing used to hit.
struct CompactPillView: View {
    @ObservedObject var store: SessionStore
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
            Text("\(store.activeBadgeCount)")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            if !store.pendingPermissions.isEmpty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .help("Permission request pending")
            }
            Text(headline)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onExpand) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Expand floating panel")
        }
        .padding(.horizontal, 12)
        .frame(
            width: FloatingPanelController.pillSize.width,
            height: FloatingPanelController.pillSize.height
        )
        // Pill lives in a borderless + transparent NSPanel; it paints its
        // own background and clips to a rounded rect so the window shadow
        // follows the rounded shape.
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var headline: String {
        if let s = store.mostRecentActiveSession { return s.projectLabel }
        if store.sessions.isEmpty { return "No sessions" }
        return "Idle"
    }
}
