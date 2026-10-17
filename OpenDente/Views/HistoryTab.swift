import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension HistoryMetric {
    var title: String {
        switch self {
        case .charge: L10n.tr("Battery Charge")
        case .temperature: L10n.tr("Temperature")
        case .batteryPower: L10n.tr("Battery Power")
        case .adapterPower: L10n.tr("Adapter Power")
        case .systemPower: L10n.tr("System Power")
        case .cycles: L10n.tr("Cycle Count")
        case .appleHealth: L10n.tr("Apple Maximum Capacity")
        case .openDenteHealth: L10n.tr("OpenDente Capacity / Design")
        }
    }
    var unit: String {
        switch self {
        case .charge, .appleHealth, .openDenteHealth: "%"
        case .temperature: "°C"
        case .batteryPower, .adapterPower, .systemPower: "W"
        case .cycles: L10n.tr("cycles")
        }
    }
    var color: Color {
        switch self {
        case .charge: .green
        case .temperature: .orange
        case .batteryPower: .teal
        case .adapterPower: .blue
        case .systemPower: .purple
        case .cycles: .secondary
        case .appleHealth: .blue
        case .openDenteHealth: .green
        }
    }
}

private enum HistoryRange: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30
    var id: Int { rawValue }
    @MainActor var title: String {
        switch self { case .day: L10n.tr("24 hours"); case .week: L10n.tr("7 days"); case .month: L10n.tr("30 days") }
    }
}

struct HistoryTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var recorder = LocalActivityRecorder.shared
    @ObservedObject private var preferences = LocalActivityPreferences.shared
    @State private var range = HistoryRange.day
    @State private var metric = HistoryMetric.charge
    @State private var plotEnd = Date()
    @State private var snapshot = LocalHistorySnapshot(minutes: [], dailyHealth: [], damagedRecords: 0)
    @State private var loading = false
    @State private var error: String?
    @State private var showClearConfirmation = false
    @State private var requestID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Picker(L10n.tr("Range"), selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Picker(L10n.tr("Metric"), selection: $metric) {
                        ForEach(HistoryMetric.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: 205)
                }
                GroupBox {
                    HistoryChart(
                        series: [HistoryChartSeries(metric: metric, points: HistoryPlot.points(snapshot.minutes, metric: metric, maximumPoints: .max))],
                        interval: DateInterval(start: plotEnd.addingTimeInterval(-Double(range.rawValue) * 86_400), end: plotEnd),
                        loading: loading
                    ).padding(8)
                }
                Text(L10n.tr("One-minute averages, stored only on this Mac. Gaps mean no usable reading; OpenDente does not reconstruct time while closed or asleep."))
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox {
                    HistoryChart(series: [
                        HistoryChartSeries(metric: .appleHealth, points: HistoryPlot.dailyPoints(snapshot.dailyHealth, metric: .appleHealth)),
                        HistoryChartSeries(metric: .openDenteHealth, points: HistoryPlot.dailyPoints(snapshot.dailyHealth, metric: .openDenteHealth))
                    ], isDaily: true).padding(8)
                    Text(L10n.tr("Up to 12 months. Each day keeps its last available readings; Apple capacity and OpenDente capacity/design remain separate measurements."))
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                GroupBox {
                    HistoryChart(series: [
                        HistoryChartSeries(metric: .cycles, points: HistoryPlot.dailyPoints(snapshot.dailyHealth, metric: .cycles))
                    ], isDaily: true).padding(8)
                }
                if loading { ProgressView().controlSize(.small) }
                if snapshot.damagedRecords > 0 {
                    Label(L10n.format(snapshot.damagedRecords == 1
                          ? "%d damaged record was skipped. Valid records remain available."
                          : "%d damaged records were skipped. Valid records remain available.", snapshot.damagedRecords),
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let error = error ?? recorder.storageError {
                    Text(L10n.tr(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                GroupBox(L10n.tr("Retention")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L10n.tr("Minute Readings"), selection: $preferences.minuteRetentionDays) {
                            ForEach([7, 30, 90], id: \.self) { Text(L10n.format("%d days", $0)).tag($0) }
                        }
                        Text(L10n.tr("Daily capacity summaries: 12 months. Older files are removed automatically. Reducing retention deletes older data."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                HStack {
                    Button(L10n.tr("Refresh")) { Task { await reload() } }
                    Button(L10n.tr("Export History…")) { export() }
                    Spacer()
                    Button(L10n.tr("Clear History…"), role: .destructive) { showClearConfirmation = true }
                }.font(.caption)
            }.padding(20)
        }
        .task { await reload() }
        .onChange(of: range) { _, _ in Task { await reload() } }
        .onChange(of: recorder.revision) { _, _ in Task { await reload() } }
        .confirmationDialog(L10n.tr("Clear all local history and daily capacity summaries?"), isPresented: $showClearConfirmation) {
            Button(L10n.tr("Clear History"), role: .destructive) {
                Task {
                    do { try await recorder.clearHistory(); await reload() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button(L10n.tr("Cancel"), role: .cancel) { }
        }
    }

    private func reload() async {
        let id = UUID()
        requestID = id
        loading = true
        let end = Date()
        let since = end.addingTimeInterval(-Double(range.rawValue) * 86_400)
        do {
            let value = try await recorder.store.history(since: since)
            guard requestID == id else { return }
            snapshot = value
            plotEnd = end
            error = nil
        } catch {
            guard requestID == id else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Export Local History")
        panel.prompt = L10n.tr("Export")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenDente-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { let data = try await recorder.store.exportHistory(); try data.write(to: url, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }
}

enum HistoryChartMarkers {
    /// Single-point segments need a symbol because they cannot form a line.
    /// Count each segment once, before Chart evaluates its individual marks.
    static func segmentsRequiringMarkers(_ points: [HistoryPlotPoint]) -> Set<Int> {
        if points.count < 3 { return Set(points.map(\.segment)) }
        var counts: [Int: Int] = [:]
        for point in points { counts[point.segment, default: 0] += 1 }
        return Set(counts.compactMap { $0.value == 1 ? $0.key : nil })
    }
}
