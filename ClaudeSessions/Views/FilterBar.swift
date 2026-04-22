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
                HStack(spacing: 6) {
                    AllPill(active: store.allSelected) { store.setAll() }
                    ForEach(SessionStatus.allCases, id: \.self) { status in
                        Pill(
                            label: status.label,
                            symbol: status.symbol,
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
                    Image(systemName: "clock").font(.caption2)
                    Text(currentAgeLabel).font(.caption.weight(.medium))
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.12))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Hide done sessions older than this")
            .padding(.trailing, 10)
        }
        .padding(.vertical, 8)
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
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct Pill: View {
    let label: String
    let symbol: String
    let count: Int
    let isOn: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? color.opacity(0.18) : Color.gray.opacity(0.10))
            .foregroundStyle(isOn ? color : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(count == 0 ? 0.55 : 1.0)
    }
}
