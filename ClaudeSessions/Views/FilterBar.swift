import SwiftUI

struct FilterBar: View {
    @ObservedObject var store: SessionStore

    private static let ageOptions: [(label: String, hours: Int)] = [
        ("Last 1h", 1),
        ("Last 6h", 6),
        ("Last 24h", 24),
        ("Last 3d", 72),
        ("Last 7d", 168)
    ]

    private var currentAgeLabel: String {
        Self.ageOptions.first(where: { $0.hours == store.doneMaxAgeHours })?.label
            ?? "Last \(store.doneMaxAgeHours)h"
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    AllPill(active: store.allSelected) { store.setAll() }
                    DotPill(
                        label: "Active",
                        count: store.activeGroupCount,
                        isOn: store.activeGroupSelected,
                        color: .green
                    ) {
                        store.toggleActiveGroup()
                    }
                    ForEach([SessionStatus.done, SessionStatus.error], id: \.self) { status in
                        DotPill(
                            label: status.label,
                            count: store.counts[status] ?? 0,
                            isOn: store.selectedStatuses.contains(status),
                            color: color(for: status)
                        ) {
                            store.toggle(status)
                        }
                    }
                }
                .padding(.leading, 10)
            }

            Menu {
                Picker("Done sessions from", selection: $store.doneMaxAgeHours) {
                    ForEach(Self.ageOptions, id: \.hours) { opt in
                        Text(opt.label).tag(opt.hours)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(currentAgeLabel)
                        .font(.system(size: 11, weight: .medium))
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(.secondary)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Hide done sessions older than this")
            .padding(.trailing, 10)
        }
        .padding(.vertical, 6)
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .running: return .green
        case .pending: return .orange
        case .idle:    return .gray
        case .done:    return .blue
        case .error:   return .red
        }
    }
}

private struct AllPill: View {
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("All")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        active
                            ? Color.accentColor.opacity(0.18)
                            : Color.primary.opacity(0.06)
                    )
                )
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct DotPill: View {
    let label: String
    let count: Int
    let isOn: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isOn
                        ? color.opacity(0.16)
                        : Color.primary.opacity(0.04)
                )
            )
            .foregroundStyle(isOn ? color : .secondary)
        }
        .buttonStyle(.plain)
        .opacity(count == 0 ? 0.55 : 1.0)
    }
}
