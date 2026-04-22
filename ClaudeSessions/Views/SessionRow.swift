import SwiftUI

struct SessionRow: View {
    let session: Session
    var pendingPermission: PendingPermission? = nil
    var onAllow: (() -> Void)? = nil
    var onDeny: (() -> Void)? = nil

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: session.status)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let pid = session.pid {
                        Text("pid \(pid)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if session.isAwaitingPermission {
                        PermissionBadge()
                    }
                    Spacer(minLength: 0)
                    Text(Self.relative.localizedString(for: session.lastActivity, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let pending = pendingPermission {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pending.summary)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Button("Allow") { onAllow?() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .tint(.green)
                            Button("Deny") { onDeny?() }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(.red)
                        }
                    }
                } else if session.isAwaitingPermission, let t = session.pendingTool {
                    Text("Awaiting permission: \(t.name)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(session.lastMessagePreview.isEmpty ? "(no messages)" : session.lastMessagePreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if session.pid != nil {
                Button {
                    TerminalFocuser.focusTerminal(for: session)
                } label: {
                    Image(systemName: "terminal")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.hostAppName.map { "Focus terminal (\($0))" } ?? "Focus terminal")
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

struct PermissionBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.raised.fill").font(.caption2)
            Text("permission").font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.orange.opacity(0.18))
        .foregroundStyle(Color.orange)
        .clipShape(Capsule())
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var body: some View {
        Image(systemName: status.symbol)
            .font(.caption)
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
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
