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

private struct HistoryRequest: Equatable {
    let range: HistoryRange
    let metric: HistoryMetric
    let revision: UInt64
    let refresh: UInt
}

struct HistoryTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var recorder = LocalActivityRecorder.shared
    @ObservedObject private var preferences = LocalActivityPreferences.shared
    @State private var range = HistoryRange.day
    @State private var metric = HistoryMetric.charge
    @State private var plotEnd = Date()
    @State private var minuteSeries: [HistoryChartSeries] = []
    @State private var history = ActivityChartHistory()
    @State private var powerSeries: [HistoryChartSeries] = []
    @State private var showHealth = false
    @State private var healthDays = 30
    @State private var selection: Date?
    @State private var browsingEvents = false
    @State private var pinnedEvent: Date?
    @State private var events: [LocalActivityEvent] = []
    @State private var eventsByMinute: [Date: [LocalActivityEvent]] = [:]
    @State private var markerDates: [Date] = []
    @State private var eventDamage = 0
    @State private var eventError: String?
    @State private var damagedRecords = 0
    @State private var loading = false
    @State private var error: String?
    @State private var showClearConfirmation = false
    @State private var refresh: UInt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.tr("History"), selection: $showHealth) {
                    Text(L10n.tr("Battery activity")).tag(false)
                    Text(L10n.tr("Battery health")).tag(true)
                }.pickerStyle(.segmented)
                if showHealth { healthPanel } else { activityPanel }
                if loading { ProgressView().controlSize(.small) }
                if damagedRecords + eventDamage > 0 {
                    Label(L10n.format(damagedRecords + eventDamage == 1
                          ? "%d damaged record was skipped. Valid records remain available."
                          : "%d damaged records were skipped. Valid records remain available.", damagedRecords + eventDamage),
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let error = error ?? eventError ?? recorder.storageError {
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
                    Button(L10n.tr("Refresh")) { refresh &+= 1 }
                    Button(L10n.tr("Export History…")) { export() }
                    Spacer()
                    Button(L10n.tr("Clear History…"), role: .destructive) { showClearConfirmation = true }
                }.font(.caption)
            }.padding(20)
        }
        .task(id: HistoryRequest(range: range, metric: metric, revision: recorder.historyRevision, refresh: refresh)) {
            await reload()
        }
        .task(id: HistoryRequest(range: range, metric: .charge, revision: recorder.eventRevision, refresh: refresh)) {
            let end = Date()
            do {
                let snapshot = try await recorder.store.timeline(since: end.addingTimeInterval(-duration), until: end)
                try Task.checkCancellation()
                events = snapshot.events
                eventsByMinute = Dictionary(grouping: events) { MinuteHistoryAccumulator.minute($0.timestamp) }
                // Nearby markers share a symbol at long ranges. The event picker retains every timestamp.
                let bins = Dictionary(grouping: events) { Int($0.timestamp.timeIntervalSince1970 / (duration / 240)) }
                markerDates = bins.values.compactMap { $0.first?.timestamp }.sorted()
                eventDamage = snapshot.damagedRecords
                eventError = nil
            } catch { if !Task.isCancelled { eventError = error.localizedDescription } }
        }
        .onChange(of: range) { _, _ in pinnedEvent = nil; selection = nil }
        .confirmationDialog(L10n.tr("Clear all local history and daily capacity summaries?"), isPresented: $showClearConfirmation) {
            Button(L10n.tr("Clear History"), role: .destructive) {
                Task {
                    do { try await recorder.clearHistory() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button(L10n.tr("Cancel"), role: .cancel) { }
        }
    }

    private var duration: Double { Double(range.rawValue) * 86_400 }
    private var interval: DateInterval { DateInterval(start: plotEnd.addingTimeInterval(-duration), end: plotEnd) }
    private var sharedSelection: Binding<Date?> {
        Binding(get: { selection ?? pinnedEvent }, set: { selection = $0 })
    }

    @ViewBuilder private var activityPanel: some View {
        HStack {
            Picker(L10n.tr("Range"), selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker(L10n.tr("Metric"), selection: $metric) {
                ForEach(HistoryMetric.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(maxWidth: 205)
        }
        GroupBox(L10n.tr("Period summary")) {
            VStack(alignment: .leading, spacing: 6) {
                summaryGrid
                Text(L10n.tr("Durations and Wh use consecutive readings with recorded context. Older readings and gaps can reduce coverage."))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        chartsAndEvents
    }

    private var summaryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            summaryRow("First → last charge", percent(history.firstCharge) + " → " + percent(history.lastCharge))
            summaryRow("AC power / battery", time(history.usage.acSeconds) + " / " + time(history.usage.batterySeconds))
            summaryRow("Power source unknown", time(max(0, duration - history.usage.acSeconds - history.usage.batterySeconds)))
            let measured = history.usage.energySeconds > 0
            summaryRow("Estimated energy in / out", measured ? L10n.number(history.usage.chargedWh, fractionDigits: 2) + " / " + L10n.number(history.usage.dischargedWh, fractionDigits: 2) + " Wh" : "—")
            summaryRow("Time with measured power", time(history.usage.energySeconds))
        }
    }

    @ViewBuilder private var chartsAndEvents: some View {
        GroupBox {
            HistoryChart(series: minuteSeries, interval: interval, loading: loading, selection: sharedSelection,
                         targets: history.targets, markerDates: metric == .charge ? markerDates : [],
                         onMarker: { pinnedEvent = $0; selection = nil }).padding(8)
            if metric == .charge {
                HStack {
                    if !history.targets.isEmpty { Text(L10n.tr("Dashed line · Recorded charge limit")) }
                    if !events.isEmpty { Text(L10n.tr("◆ Recorded events")).foregroundStyle(.orange) }
                }.font(.caption)
            }
        }
        if metric == .charge {
            GroupBox {
                HistoryChart(series: powerSeries, interval: interval, loading: loading, selection: sharedSelection).padding(8)
                Text(L10n.tr("Positive watts charge the battery. Negative watts leave the battery.")).font(.caption)
            }
        }
        if let date = sharedSelection.wrappedValue {
            let minute = MinuteHistoryAccumulator.minute(date)
            Text(L10n.date(date, includeTime: true) + " · " + L10n.tr(history.sources[minute].map { $0 ? "AC Power" : "Running on Battery" } ?? "Power source unknown"))
            ForEach(eventsByMinute[minute] ?? []) { Text($0.summary).font(.callout) }
        }
        if !events.isEmpty {
            HStack {
                Button(L10n.tr("Select an event")) { browsingEvents = true }
                    .popover(isPresented: $browsingEvents) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(events.reversed()) { event in
                                    Button {
                                        pinnedEvent = event.timestamp
                                        selection = nil
                                        browsingEvents = false
                                    } label: {
                                        Text(L10n.date(event.timestamp, includeTime: true) + " · " + event.summary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.link)
                                }
                            }.padding()
                        }.frame(width: 380, height: 240)
                    }
                if pinnedEvent != nil {
                    Button(L10n.tr("Latest Reading")) { pinnedEvent = nil; selection = nil }
                }
            }
        }
        Text(L10n.tr("One-minute averages, stored only on this Mac. Gaps mean no usable reading; OpenDente does not reconstruct time while closed or asleep."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func summaryRow(_ key: String, _ value: String) -> some View {
        GridRow { Text(L10n.tr(key)).foregroundStyle(.secondary); Text(value).monospacedDigit() }
    }
    private func percent(_ value: Double?) -> String { value.map { L10n.number($0) + " %" } ?? "—" }
    private func time(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2,
                                                                  zeroValueUnits: .hide).locale(L10n.locale))
    }

    @ViewBuilder private var healthPanel: some View {
        Picker(L10n.tr("Range"), selection: $healthDays) {
            ForEach([30, 90, 366], id: \.self) { days in
                Text(days == 366 ? L10n.tr("12 months") : L10n.format("%d days", days)).tag(days)
            }
        }.pickerStyle(.segmented)
        let start = LocalActivityStore.day(plotEnd).addingTimeInterval(-Double(healthDays - 1) * 86400)
        let rows = history.dailyHealth.filter { $0.day >= start }
        let all = [HistoryMetric.appleHealth, .openDenteHealth, .cycles].map {
            HistoryChartSeries(metric: $0, points: HistoryPlot.dailyPoints(rows, metric: $0))
        }
        ForEach(all.indices, id: \.self) { i in
            if let first = all[i].points.first, let last = all[i].points.last, first.timestamp != last.timestamp {
                let change = last.value - first.value
                Text(all[i].metric.title + " · " + (change > 0 ? "+" : "") + L10n.number(change, fractionDigits: i == 2 ? 0 : 1)
                     + " " + (i == 2 ? all[i].metric.unit : L10n.tr("percentage points")) + " · "
                     + L10n.date(first.timestamp, timeZone: .gmt) + " → " + L10n.date(last.timestamp, timeZone: .gmt)).font(.caption)
            }
        }
        let period = DateInterval(start: start, end: plotEnd)
        GroupBox { HistoryChart(series: Array(all.prefix(2)), interval: period, isDaily: true).padding(8) }
        GroupBox { HistoryChart(series: [all[2]], interval: period, isDaily: true).padding(8) }
    }

    private func reload() async {
        let selectedMetric = metric
        loading = true
        let end = Date()
        let since = end.addingTimeInterval(-Double(range.rawValue) * 86_400)
        do {
            let value = try await recorder.store.chartHistory(since: since, metric: selectedMetric, now: end)
            try Task.checkCancellation()
            minuteSeries = [HistoryChartSeries(metric: selectedMetric, points: value.points)]
            history = value
            powerSeries = [HistoryChartSeries(metric: .batteryPower, points: value.power)]
            damagedRecords = value.damagedRecords
            plotEnd = end
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
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
            do { try await recorder.store.exportHistory(to: url) }
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
