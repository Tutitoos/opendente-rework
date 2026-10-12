import Foundation
import Testing
@testable import OpenDente

@Suite("History chart presentation")
struct HistoryChartPresentationTests {
    @Test func threeSingleMinuteSessionsRemainVisibleWithoutConnectingGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0..<3).map {
            minute(at: start.addingTimeInterval(Double($0 * 60)), value: Double(80 + $0))
        }
        let points = HistoryPlot.points(rows, metric: .charge)

        #expect(points.count == 3)
        #expect(Set(points.map(\.segment)).count == 3)
        #expect(HistoryChartMarkers.segmentsRequiringMarkers(points) == Set(points.map(\.segment)))
    }

    @Test func isolatedPointsKeepMarkersAlongsideMultiPointLines() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lineSession = UUID()
        let rows = [
            minute(at: start, value: 80),
            minute(at: start.addingTimeInterval(60), value: 81, session: lineSession),
            minute(at: start.addingTimeInterval(120), value: 82, session: lineSession),
            minute(at: start.addingTimeInterval(180), value: 83),
            minute(at: start.addingTimeInterval(240), value: 84)
        ]
        let points = HistoryPlot.points(rows, metric: .charge)

        #expect(points.map(\.segment) == [0, 1, 1, 2, 3])
        #expect(HistoryChartMarkers.segmentsRequiringMarkers(points) == [0, 2, 3])
    }

    @Test func shortContinuousSeriesRetainsItsPointSymbols() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UUID()
        let points = HistoryPlot.points([
            minute(at: start, value: 80, session: session),
            minute(at: start.addingTimeInterval(60), value: 81, session: session)
        ], metric: .charge)

        #expect(points.map(\.segment) == [0, 0])
        #expect(HistoryChartMarkers.segmentsRequiringMarkers(points) == [0])
        #expect(HistoryChartMarkers.segmentsRequiringMarkers([]).isEmpty)
    }

    private func minute(at date: Date, value: Double, session: UUID = UUID()) -> BatteryHistoryMinute {
        BatteryHistoryMinute(schemaVersion: 1, sessionID: session, timestamp: date,
            firstObservedAt: date, lastObservedAt: date.addingTimeInterval(58), readingCount: 1,
            validChargeReadingCount: 1, averages: [HistoryMetric.charge.rawValue: value],
            valueCounts: [HistoryMetric.charge.rawValue: 1],
            metricLastObservedAt: [HistoryMetric.charge.rawValue: date.addingTimeInterval(58)],
            sources: [HistoryMetric.charge.rawValue: [BatteryDataSource.iops.rawValue]],
            healthQualities: [BatteryDataQuality.valid.rawValue])
    }
}
