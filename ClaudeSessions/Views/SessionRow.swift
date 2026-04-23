import SwiftUI

struct SessionRow: View {
    let session: Session
    var pendingPermission: PendingPermission? = nil
    var onAllow: (() -> Void)? = nil
    var onDeny: (() -> Void)? = nil
    var onOpenHistory: (() -> Void)? = nil
    /// Called when the user taps the permission card anywhere outside the
    /// Allow/Deny buttons — lets them hop to the terminal to inspect/answer
    /// in context rather than deciding blind from the menubar.
    var onFocusTerminal: (() -> Void)? = nil

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if pendingPermission != nil {
            permissionCard
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: session.status)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("#\(session.id.prefix(6))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if let pid = session.pid {
                        Text("pid \(pid)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if session.isAwaitingPermission {
                        PermissionBadge()
                    }
                    Spacer(minLength: 0)
                    Text(Self.relative.localizedString(for: session.lastActivity, relativeTo: Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if session.isAwaitingPermission, let t = session.pendingTool {
                    Text("Awaiting permission: \(t.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(session.lastMessagePreview.isEmpty ? "(no messages)" : session.lastMessagePreview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button {
                onOpenHistory?()
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open chat history")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .pointerCursor()
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(session.projectLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let pid = session.pid {
                    Text("pid \(pid)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(Self.relative.localizedString(for: session.lastActivity, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 8) {
                PermissionBadge()
                if let pending = pendingPermission {
                    Text(pending.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button("Allow") { onAllow?() }
                    .buttonStyle(PillActionStyle(tint: .green, prominent: true))
                    .pointerCursor()
                Button("Deny") { onDeny?() }
                    .buttonStyle(PillActionStyle(tint: .red, prominent: false))
                    .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
        )
        // Make the card tappable as a whole; the Allow/Deny Buttons above
        // capture their own taps, so only the surrounding area routes here.
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onFocusTerminal?() }
        .pointerCursor()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct PillActionStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? tint.opacity(0.9) : tint.opacity(0.14))
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

struct PermissionBadge: View {
    var body: some View {
        Text("PERMISSION")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(Color.orange)
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.5), radius: 2, x: 0, y: 0)
    }
    private var color: Color {
        switch status {
        case .running: return .green
        case .pending: return .orange
        case .idle:    return .gray
        case .done:    return .blue
        case .error:   return .red
        }
    }
}
