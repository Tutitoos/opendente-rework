import SwiftUI

/// Keeps Apple's system health and the physical capacity ratio as separate readings.
struct BatteryHealthPresentation {
    let applePercentage: Int?
    let openDentePercentage: Double?

    @MainActor var appleLabel: String { applePercentage.map { "\($0)%" } ?? "—" }
    @MainActor var openDenteLabel: String {
        openDentePercentage.map { L10n.format("%.1f%%", $0) } ?? "—"
    }
}

struct BatteryHealthCard: View {
    @ObservedObject private var language = LanguageManager.shared
    let presentation: BatteryHealthPresentation
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 12 : 24) {
            reading(label: "Apple", value: presentation.appleLabel, caption: "Maximum capacity")
            Divider()
            reading(label: "OpenDente", value: presentation.openDenteLabel, caption: "Full capacity / design")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(compact ? 10 : 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func reading(label: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.tr(label)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(compact ? .headline : .title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(L10n.tr(caption)).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
