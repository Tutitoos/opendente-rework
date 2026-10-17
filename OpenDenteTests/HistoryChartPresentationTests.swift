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

    @Test func percentageScalesKeepChargeHonestAndAllowCapacityAbove100() {
        let point = HistoryPlotPoint(timestamp: .now, value: 104.8, segment: 0)
        #expect(HistoryChartScale.valueDomain([point], metric: .charge) == 0...100)
        let capacity = HistoryChartScale.valueDomain([point], metric: .openDenteHealth)
        #expect(capacity.contains(104.8))
        #expect(capacity.contains(100))
        #expect(capacity.lowerBound > 0)
    }

    @Test func signedPowerKeepsBothDirectionsAndZeroVisible() {
        let points = [-8.5, 13.2].map { HistoryPlotPoint(timestamp: .now, value: $0, segment: 0) }
        let domain = HistoryChartScale.valueDomain(points, metric: .batteryPower)
        #expect(domain.contains(-8.5))
        #expect(domain.contains(0))
        #expect(domain.contains(13.2))
    }

    @Test(arguments: [HistoryMetric.temperature, .cycles, .adapterPower])
    func flatZeroReadingsHaveUsableScales(metric: HistoryMetric) {
        let domain = HistoryChartScale.valueDomain([.init(timestamp: .now, value: 0, segment: 0)], metric: metric)
        #expect(domain.lowerBound < domain.upperBound)
        #expect(domain.contains(0))
        if metric == .cycles { #expect(domain.lowerBound >= 0) }
    }

    @Test func inspectionDoesNotInventReadingsInGapsOrBeyondTheSeries() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [
            HistoryPlotPoint(timestamp: start, value: 80, segment: 0),
            HistoryPlotPoint(timestamp: start.addingTimeInterval(3600), value: 70, segment: 1)
        ]
        #expect(HistoryChartScale.nearestPoint(to: start.addingTimeInterval(30), in: points, tolerance: 60)?.value == 80)
        #expect(HistoryChartScale.nearestPoint(to: start.addingTimeInterval(1800), in: points, tolerance: 60) == nil)
        #expect(HistoryChartScale.nearestPoint(to: start.addingTimeInterval(-61), in: points, tolerance: 60) == nil)
        #expect(HistoryChartScale.nearestPoint(to: start, in: [], tolerance: 60) == nil)
    }

    @Test func inspectionSelectsTheClosestRealPointWithDeterministicTies() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0..<3).map { HistoryPlotPoint(timestamp: start.addingTimeInterval(Double($0 * 60)), value: Double($0), segment: 0) }
        #expect(HistoryChartScale.nearestPoint(to: start.addingTimeInterval(30), in: points, tolerance: 60)?.value == 0)
        #expect(HistoryChartScale.nearestPoint(to: start.addingTimeInterval(100), in: points, tolerance: 60)?.value == 2)
        #expect(HistoryChartScale.nearestPoint(to: start.addingTimeInterval(120), in: points, tolerance: 60)?.value == 2)
    }

    @Test func inspectionRetainsMinuteResolutionWhenDrawingIsDownsampled() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0..<3000).map {
            HistoryPlotPoint(timestamp: start.addingTimeInterval(Double($0 * 60)), value: Double($0 % 100), segment: 0)
        }
        let series = HistoryChartSeries(metric: .charge, points: points)
        let inspected = series.reading(at: start.addingTimeInterval(501 * 60), isDaily: false)
        #expect(inspected?.timestamp == start.addingTimeInterval(501 * 60))
        #expect(inspected?.value == 1)
        #expect(!series.plottedPoints.contains { $0.timestamp == inspected?.timestamp })
    }

    @Test func dailyInspectionLeavesMissingDaysEmptyAndRestoresTheLatestReading() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let series = HistoryChartSeries(metric: .appleHealth, points: [
            .init(timestamp: start, value: 99, segment: 0),
            .init(timestamp: start.addingTimeInterval(2 * 86_400), value: 98, segment: 1)
        ])
        #expect(series.reading(at: start.addingTimeInterval(86_400), isDaily: true) == nil)
        #expect(series.reading(at: nil, isDaily: true)?.value == 98)
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
