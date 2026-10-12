import Foundation
import Testing
@testable import OpenDente

@Suite("Local battery activity")
struct LocalActivityTests {
    @Test func constructionIsInert() async throws {
        let folder = temporaryActivityDirectory()
        _ = LocalActivityStore(directory: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func minuteAveragesOnlyObservedValuesAndPreservesSources() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var accumulator = MinuteHistoryAccumulator()
        let initial = accumulator.add(.init(timestamp: date, values: [.charge: 80, .temperature: 30],
                                            sources: ["charge": "iops", "temperature": "smc"]))
        let sameMinute = accumulator.add(.init(timestamp: date.addingTimeInterval(2), values: [.charge: 82],
                                               sources: ["charge": "iops"]))
        let flushed = accumulator.add(.init(timestamp: date.addingTimeInterval(600), values: [.charge: 90]))
        #expect(initial == nil)
        #expect(sameMinute == nil)
        let row = try #require(flushed)
        #expect(row.value(.charge) == 81)
        #expect(row.value(.temperature) == 30)
        #expect(row.value(.systemPower) == nil)
        #expect(row.readingCount == 2)
        #expect(row.valueCounts["temperature"] == 1)
        #expect(row.sources["charge"] == ["iops"])
        let last = accumulator.flush()
        let empty = accumulator.flush()
        #expect(last?.firstObservedAt == date.addingTimeInterval(600))
        #expect(empty == nil)
    }

    @Test func invalidChargeAndSensorsAreNotConvertedIntoZeroMeasurements() {
        var state = makeLocalActivityBattery()
        state.hasValidBatteryReading = false
        let reading = BatteryHistoryReading(state: state, at: Date())
        #expect(reading.values[.charge] == nil)
        #expect(!reading.chargeValid)
        #expect(reading.values[.appleHealth] == 100)
        #expect(reading.values[.openDenteHealth] == 95)
        state.healthDataQuality = .invalid
        #expect(BatteryHistoryReading(state: state, at: Date()).values[.openDenteHealth] == nil)
    }

    @Test func sessionsMissingMetricsAndLongPausesSplitGraphs() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UUID()
        let first = activityMinute(now, values: [.charge: 80], session: session)
        let missing = activityMinute(now.addingTimeInterval(60), values: [.temperature: 30], session: session)
        let second = activityMinute(now.addingTimeInterval(120), values: [.charge: 82], session: session)
        let paused = activityMinute(now.addingTimeInterval(900), values: [.charge: 84], session: session)
        let restarted = activityMinute(now.addingTimeInterval(960), values: [.charge: 85])
        let points = HistoryPlot.points([first, missing, second, paused, restarted], metric: .charge)
        #expect(points.count == 4)
        #expect(Set(points.map(\.segment)).count == 4)
        let adjacent = HistoryPlot.points([first, activityMinute(now.addingTimeInterval(60),
            values: [.charge: 81], session: session)], metric: .charge)
        #expect(Set(adjacent.map(\.segment)).count == 1)
    }

    @Test func downsamplingNeverBridgesGapSegments() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UUID()
        let rows = (0..<90).map { index in activityMinute(start.addingTimeInterval(Double(index * 60)),
            values: [.charge: Double(index)], session: session) }
            + [activityMinute(start.addingTimeInterval(9000), values: [.charge: 95], session: session)]
        let points = HistoryPlot.points(rows, metric: .charge, maximumPoints: 10)
        #expect(Set(points.map(\.segment)).count == 2)
        #expect(points.first?.value == 0)
        #expect(points.contains { $0.value == 89 })
        #expect(points.last?.value == 95)
    }

    @Test func persistenceReopensAndWritesIncrementally() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalActivityStore(directory: folder)
        try await store.append(activityMinute(date, values: [.charge: 80, .appleHealth: 100, .openDenteHealth: 95]), now: date)
        let partition = try #require(FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("minutes"),
            includingPropertiesForKeys: nil).first)
        let firstBytes = try Data(contentsOf: partition)
        try await store.append(activityMinute(date.addingTimeInterval(60), values: [.charge: 81]), now: date.addingTimeInterval(60))
        let laterBytes = try Data(contentsOf: partition)
        #expect(laterBytes.starts(with: firstBytes))
        #expect(laterBytes.count > firstBytes.count)
        let reopened = LocalActivityStore(directory: folder)
        let snapshot = try await reopened.history(since: date.addingTimeInterval(-1), now: date.addingTimeInterval(120))
        #expect(snapshot.minutes.count == 2)
        #expect(snapshot.dailyHealth.count == 1)
        #expect(snapshot.dailyHealth.first?.applePercentage == 100)
        #expect(snapshot.dailyHealth.first?.openDentePercentage == 95)
        // A missing later health value retains its actual earlier observation timestamp.
        #expect(snapshot.dailyHealth.first?.appleObservedAt == date.addingTimeInterval(58))
        #expect(snapshot.damagedRecords == 0)
    }

    @Test func retentionKeepsDailyHealthAfterMinuteHistoryExpires() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-50 * 86400)
        let expired = now.addingTimeInterval(-400 * 86400)
        let store = LocalActivityStore(directory: folder)
        try await store.append(activityMinute(expired, values: [.appleHealth: 100]), now: expired)
        try await store.append(activityMinute(old, values: [.appleHealth: 99]), now: old)
        try await store.append(activityMinute(now, values: [.appleHealth: 98]), now: now)
        try await store.prune(now: now)
        let snapshot = try await store.history(since: expired, now: now)
        #expect(snapshot.minutes.count == 1)
        #expect(snapshot.dailyHealth.count == 2)
        #expect(snapshot.dailyHealth.first?.applePercentage == 99)
        let short = LocalActivityRetention(minuteDays: 1, eventDays: 1, healthDays: 1)
        try await store.setRetention(short, now: now)
        #expect(try await store.history(since: expired, now: now).dailyHealth.count == 1)
    }

    @Test func truncatedRecordRecoveryPreservesValidRecordsAndSubsequentAppend() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalActivityStore(directory: folder)
        try await store.append(activityMinute(date, values: [.charge: 80]), now: date)
        let partition = try #require(FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("minutes"),
            includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: partition)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schemaVersion\":".utf8))
        try handle.close()
        try await store.append(activityMinute(date.addingTimeInterval(60), values: [.charge: 81]), now: date.addingTimeInterval(60))
        let snapshot = try await store.history(since: date.addingTimeInterval(-1), now: date.addingTimeInterval(120))
        #expect(snapshot.minutes.count == 2)
        #expect(snapshot.damagedRecords == 1)
    }

    @Test func structuredEventsDeduplicateAndFilterWithoutPersistingTranslatedText() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalActivityStore(directory: folder)
        let first = LocalActivityEvent(at: date, category: .nativePolicy, code: "native.limitConfirmed", values: ["limit": "80"])
        #expect(try await store.append(first, now: date))
        #expect(try await !store.append(.init(at: date.addingTimeInterval(2), category: .nativePolicy,
            code: first.code, values: first.values), now: date.addingTimeInterval(2)))
        #expect(try await store.append(.init(at: date.addingTimeInterval(4), category: .helper, severity: .error,
            code: "helper.unavailable"), now: date.addingTimeInterval(4)))
        let events = try await store.events(now: date.addingTimeInterval(10))
        #expect(events.events.count == 2)
        #expect(events.events.filter { $0.matches(category: .nativePolicy, severity: nil, search: "80") }.count == 1)
        #expect(events.events.filter { $0.matches(category: .helper, severity: .error, search: "unavailable") }.count == 1)
        let exported = try await store.exportEvents(now: date.addingTimeInterval(10))
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("native.limitConfirmed"))
        #expect(!text.contains("Charge limit confirmed"))
    }

    @Test func exportsContainSourcesQualityAndNoAdapterSerial() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalActivityStore(directory: folder)
        var accumulator = MinuteHistoryAccumulator()
        _ = accumulator.add(.init(state: makeLocalActivityBattery(), at: date))
        let row = accumulator.flush()
        try await store.append(try #require(row), now: date)
        let exported = try await store.exportHistory(now: date.addingTimeInterval(60))
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("systemProfiler"))
        #expect(text.contains("ioRegistry"))
        #expect(text.contains("valid"))
        #expect(text.contains("appleHealth"))
        #expect(text.contains("openDenteHealth"))
        #expect(!text.contains("PRIVATE-ADAPTER-SERIAL"))
        #expect(!text.contains("serial"))
    }

    @Test func clearingHistoryPreservesEventLog() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalActivityStore(directory: folder)
        try await store.append(activityMinute(date, values: [.charge: 80]), now: date)
        try await store.append(.init(at: date, category: .application, code: "application.started"), now: date)
        try await store.clearHistory()
        #expect(try await store.history(since: date, now: date).minutes.isEmpty)
        #expect(try await store.events(now: date).events.count == 1)
        try await store.clearEvents()
        #expect(try await store.events(now: date).events.isEmpty)
    }
}

private func temporaryActivityDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("OpenDente-activity-tests-\(UUID().uuidString)")
}
private func activityMinute(_ date: Date, values: [HistoryMetric: Double], session: UUID = UUID()) -> BatteryHistoryMinute {
    var accumulator = MinuteHistoryAccumulator(sessionID: session)
    _ = accumulator.add(.init(timestamp: date, values: values,
                              sources: ["charge": "iops", "appleHealth": "systemProfiler"], healthQuality: "valid"))
    _ = accumulator.add(.init(timestamp: date.addingTimeInterval(58), values: values,
                              sources: ["charge": "iops", "appleHealth": "systemProfiler"], healthQuality: "valid"))
    return accumulator.flush()!
}
private func makeLocalActivityBattery() -> BatteryState {
    let adapter = AdapterInfo(name: "Adapter", description: nil, manufacturer: nil, model: nil, watts: 60,
        voltage: 20, current: 3, serial: "PRIVATE-ADAPTER-SERIAL", firmware: nil, isWireless: false,
        usbPDProfiles: [], activeProfileIndex: nil)
    return BatteryState(percentage: 80, hardwarePercentage: 79, isCharging: false, isPluggedIn: true,
        currentCapacity: 4000, maxCapacity: 5700, designCapacity: 6000, cycleCount: 37,
        temperature: 31, voltage: 12, amperage: 0, systemPower: 12, adapterPower: 15, adapterInfo: adapter,
        batteryPower: 0, notChargingReason: 0x1000000, chargerInhibitReason: 0,
        timeToEmpty: nil, timeToFull: nil, hasValidBatteryReading: true, systemMaximumCapacityPercentage: 100,
        systemMaximumCapacitySource: .systemProfiler, capacitySource: .ioRegistry, healthDataQuality: .valid)
}
