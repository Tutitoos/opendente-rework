import Charts
import SwiftUI

struct HistoryChartSeries {
    let metric: HistoryMetric
    let points: [HistoryPlotPoint]
    let plottedPoints: [HistoryPlotPoint]
    let domain: ClosedRange<Double>
    let observedRange: ClosedRange<Double>?
    let markerSegments: Set<Int>

    init(metric: HistoryMetric, points: [HistoryPlotPoint]) {
        self.metric = metric
        self.points = points
        plottedPoints = HistoryPlot.downsample(points)
        observedRange = metric != .charge || points.isEmpty ? nil : points.reduce(points[0].value...points[0].value) {
            min($0.lowerBound, $1.value)...max($0.upperBound, $1.value)
        }
        domain = HistoryChartScale.valueDomain(points, metric: metric)
        markerSegments = HistoryChartMarkers.segmentsRequiringMarkers(plottedPoints)
    }

    func reading(at date: Date?, isDaily: Bool) -> HistoryPlotPoint? {
        guard let date else { return points.last }
        let bucket = isDaily ? LocalActivityStore.day(date) : MinuteHistoryAccumulator.minute(date)
        return HistoryChartScale.nearestPoint(to: bucket, in: points, tolerance: 0)
    }
}

enum HistoryChartScale {
    static func valueDomain(_ points: [HistoryPlotPoint], metric: HistoryMetric) -> ClosedRange<Double> {
        if metric == .charge { return 0...100 }
        guard let first = points.first else { return 0...100 }
        var low = first.value, high = first.value
        for point in points.dropFirst() {
            low = min(low, point.value)
            high = max(high, point.value)
        }
        switch metric {
        case .charge: return 0...100
        case .appleHealth, .openDenteHealth:
            return max(0, floor((low - 2) / 5) * 5)...max(100, ceil((high + 2) / 5) * 5)
        case .cycles:
            let padding = max(1, (high - low) * 0.1)
            return max(0, floor(low - padding))...ceil(high + padding)
        case .temperature:
            let padding = max(2, (high - low) * 0.1)
            return floor(low - padding)...ceil(high + padding)
        case .batteryPower, .adapterPower, .systemPower:
            let padding = max(1, (high - low) * 0.1)
            return (low < 0 ? floor(low - padding) : 0)...(high > 0 ? ceil(high + padding) : max(0, high + 1))
        }
    }

    static func chargeDetailDomain(_ observed: ClosedRange<Double>) -> ClosedRange<Double> {
        // Five-point ticks and at least ten percentage points of context, even for a flat day.
        let low = max(0, floor((observed.lowerBound - 1) / 5) * 5)
        let high = min(100, ceil((observed.upperBound + 1) / 5) * 5)
        return min(low, 90)...max(high, min(low, 90) + 10)
    }

    /// HistoryPlot returns chronological points; do not snap across missing readings.
    static func nearestPoint(to date: Date, in points: [HistoryPlotPoint], tolerance: TimeInterval) -> HistoryPlotPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].timestamp < date { low = middle + 1 } else { high = middle }
        }
        let index: Int
        if low > 0 && (low == points.count || date.timeIntervalSince(points[low - 1].timestamp) <= points[low].timestamp.timeIntervalSince(date)) {
            index = low - 1
        } else {
            index = low
        }
        let point = points[index]
        return abs(point.timestamp.timeIntervalSince(date)) <= tolerance ? point : nil
    }
}

struct HistoryChart: View {
    @ObservedObject private var language = LanguageManager.shared
    let series: [HistoryChartSeries]
    let interval: DateInterval?
    let isDaily: Bool
    let loading: Bool
    private let valueDomain: ClosedRange<Double>
    private let timeDomain: ClosedRange<Date>
    @State private var detailScale = false
    @State private var localDate: Date?
    private let sharedDate: Binding<Date?>?
    private var selection: Binding<Date?> { sharedDate ?? $localDate }
    private var selectedDate: Date? { selection.wrappedValue }
    private let detailDomain: ClosedRange<Double>?
    private let targets: [HistoryPlotPoint]
    private let onMarker: ((Date) -> Void)?
    private let markerDates: [Date]

    init(series: [HistoryChartSeries], interval: DateInterval? = nil, isDaily: Bool = false,
         loading: Bool = false, selectedDate: Date? = nil, selection: Binding<Date?>? = nil,
         targets: [HistoryPlotPoint] = [], markerDates: [Date] = [], onMarker: ((Date) -> Void)? = nil) {
        self.series = series
        self.interval = interval
        self.isDaily = isDaily
        self.loading = loading
        _localDate = State(initialValue: selectedDate)
        sharedDate = selection
        detailDomain = series.first?.observedRange.map { observed in
            HistoryChartScale.chargeDetailDomain(targets.reduce(observed) {
                min($0.lowerBound, $1.value)...max($0.upperBound, $1.value)
            })
        }
        self.targets = targets
        self.onMarker = onMarker
        self.markerDates = markerDates
        var lower = Double.infinity, upper = -Double.infinity
        var first: Date?, last: Date?
        for item in series where !item.points.isEmpty {
            lower = min(lower, item.domain.lowerBound)
            upper = max(upper, item.domain.upperBound)
            if let date = item.points.first?.timestamp { first = min(first ?? date, date) }
            if let date = item.points.last?.timestamp { last = max(last ?? date, date) }
        }
        valueDomain = lower < upper ? lower...upper : 0...100
        if let interval {
            timeDomain = interval.start...interval.end
        } else {
            let start = first ?? Date(), end = last ?? first ?? Date()
            timeDomain = start.addingTimeInterval(-43_200)...end.addingTimeInterval(43_200)
        }
    }

    private var hasReadings: Bool { series.contains { !$0.points.isEmpty } }
    private var plotHeight: CGFloat { isDaily ? (series.first?.metric == .cycles ? 150 : 180) : 220 }
    var chartTimeZone: TimeZone { isDaily ? .gmt : .current }
    var dateFormat: Date.FormatStyle {
        var style: Date.FormatStyle = isDaily || timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound) > 2 * 86_400
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.hour().minute()
        style.timeZone = chartTimeZone
        return style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { readings }
                    VStack(alignment: .leading, spacing: 12) { readings }
                }
                if let item = series.first, item.metric == .charge, let bounds = item.observedRange {
                    VStack(alignment: .trailing, spacing: 5) {
                        Picker(L10n.tr("Chart scale"), selection: $detailScale) {
                            Text("0–100 %").tag(false)
                            Text(L10n.tr("Detail scale")).tag(true)
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize().controlSize(.small)
                        Text(L10n.format("Min %@ · Max %@", percent(bounds.lowerBound), percent(bounds.upperBound)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if hasReadings {
                plot
                if isDaily {
                    Text(L10n.tr("Daily Readings (UTC)")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.secondary)
                    Text(L10n.tr(loading ? "Loading History…" : isDaily ? "No Daily Readings Yet" : "No Readings Available"))
                    if !loading && !isDaily {
                        Text(L10n.tr("The first averaged reading appears after about one minute."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).frame(height: plotHeight)
            }
        }
        .onChange(of: timeDomain) { _, _ in selection.wrappedValue = nil }
        .onChange(of: series.first?.metric) { _, _ in selection.wrappedValue = nil }
    }


    private func percent(_ value: Double) -> String {
        L10n.number(value, fractionDigits: value.rounded() == value ? 0 : 1) + " %"
    }

    @ViewBuilder private var readings: some View {
        ForEach(series.indices, id: \.self) { index in
            let item = series[index]
            let point = item.reading(at: selectedDate, isDaily: isDaily)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.metric == .openDenteHealth ? "diamond.fill" : "circle.fill")
                        .font(.system(size: 8)).foregroundStyle(item.metric.color).accessibilityHidden(true)
                    Text(item.metric.title).font(.callout.weight(.medium))
                }
                if hasReadings {
                    Text(point.map { L10n.number($0.value, fractionDigits: isDaily && item.metric == .cycles ? 0 : 1)
                        + (item.metric == .cycles ? "" : " " + item.metric.unit) } ?? "—")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.primary)
                    if let point {
                        Text(L10n.format(selectedDate == nil ? "Latest · %@" : "Selected · %@",
                                         L10n.date(point.timestamp, includeTime: !isDaily, timeZone: chartTimeZone)))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("No Reading Here")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var plot: some View {
        let timeLabel = L10n.tr(isDaily ? "Day" : "Time")
        let focused = detailScale && series.first?.metric == .charge
        let yDomain = focused ? detailDomain ?? valueDomain : valueDomain
        return Chart {
            ForEach(markerDates, id: \.self) { date in
                PointMark(x: .value(timeLabel, date), y: .value("%", yDomain.upperBound))
                    .symbol(.diamond).symbolSize(20).foregroundStyle(.orange)
                    .accessibilityLabel(L10n.tr("Recorded event"))
            }
            ForEach(targets) { target in
                LineMark(x: .value(timeLabel, target.timestamp), y: .value("%", target.value),
                         series: .value("segment", -1 - target.segment))
                    .interpolationMethod(.stepEnd).lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .foregroundStyle(Color.secondary)
                PointMark(x: .value(timeLabel, target.timestamp), y: .value("%", target.value))
                    .symbolSize(5).foregroundStyle(Color.secondary)
            }
            if series.first?.metric == .batteryPower {
                RuleMark(y: .value("W", 0))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            ForEach(series.indices, id: \.self) { index in
                let item = series[index]
                let title = item.metric.title, unit = item.metric.unit, color = item.metric.color
                let stroke = StrokeStyle(lineWidth: 2, dash: item.metric == .openDenteHealth ? [5, 3] : [])
                ForEach(item.plottedPoints) { point in
                    LineMark(x: .value(timeLabel, point.timestamp), y: .value(unit, point.value),
                             series: .value("segment", point.segment * series.count + index))
                        .foregroundStyle(color)
                        .lineStyle(stroke)
                        .interpolationMethod(.linear)
                        .accessibilityLabel(Text(title))
                    if item.markerSegments.contains(point.segment) || (isDaily && item.plottedPoints.count <= 40) {
                        PointMark(x: .value(timeLabel, point.timestamp), y: .value(unit, point.value))
                            .foregroundStyle(color)
                            .symbol(item.metric == .openDenteHealth ? BasicChartSymbolShape.diamond : .circle)
                            .symbolSize(isDaily ? 20 : 9)
                            .accessibilityLabel(Text(title))
                    }
                }
                if selectedDate != nil, let point = item.reading(at: selectedDate, isDaily: isDaily) {
                    RuleMark(x: .value(timeLabel, point.timestamp))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value(timeLabel, point.timestamp), y: .value(unit, point.value))
                        .foregroundStyle(color)
                        .symbol(item.metric == .openDenteHealth ? BasicChartSymbolShape.diamond : .circle)
                        .symbolSize(55)
                        .accessibilityLabel(Text(title))
                }
            }
        }
        .chartXScale(domain: timeDomain, range: .plotDimension(padding: 8))
        .chartYScale(domain: yDomain, range: .plotDimension(padding: 8))
        .chartXAxis {
            AxisMarks(values: isDaily && timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound) <= 3 * 86_400
                      ? .stride(by: .day) : .automatic(desiredCount: 4)) { value in
                AxisTick()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) { Text(date, format: dateFormat) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: series.first?.metric == .cycles
                      ? .stride(by: max(1, ceil((valueDomain.upperBound - valueDomain.lowerBound) / 4)))
                      : .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel(anchor: .trailing) {
                    if let number = value.as(Double.self) {
                        Text(L10n.number(number, fractionDigits: series.first?.metric != .cycles
                                         && valueDomain.upperBound - valueDomain.lowerBound < 5 ? 1 : 0)
                             + (series.first?.metric == .cycles ? "" : " " + (series.first?.metric.unit ?? "")))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .environment(\.timeZone, chartTimeZone)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in plot.clipped() }
        .chartXSelection(value: selection)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let anchor = proxy.plotFrame else { return }
                        let frame = geometry[anchor]
                        guard frame.contains(location), location.y <= frame.minY + 22,
                              let date = markerDates.min(by: {
                                  abs((proxy.position(forX: $0) ?? -.infinity) - location.x + frame.minX)
                                  < abs((proxy.position(forX: $1) ?? -.infinity) - location.x + frame.minX)
                              }), let x = proxy.position(forX: date), abs(frame.minX + x - location.x) <= 10 else { return }
                        onMarker?(date)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            selection.wrappedValue = frame.contains(location) ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil
                        case .ended: selection.wrappedValue = nil
                        }
                    }
            }
        }
        .frame(height: plotHeight)
        .accessibilityLabel(series.count == 1 ? series[0].metric.title : L10n.tr("Apple and OpenDente Capacity"))
    }
}
