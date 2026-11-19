import Foundation
import Testing
@testable import OpenDente

@Suite("Local battery activity")
struct LocalActivityTests {
    @Test func usageSplitsAtMinuteBoundaryAndAtPowerReversal() throws {
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ offset: Double, _ watts: Double, _ ac: Bool) -> BatteryHistoryReading {
            var value = BatteryHistoryReading(timestamp: minute.addingTimeInterval(offset), values: [.batteryPower: watts])
            value.onAC = ac
            return value
        }
        var accumulator = MinuteHistoryAccumulator()
        _ = accumulator.add(sample(-4, -18, true))
        let before = try #require(accumulator.add(sample(4, 18, true))?.usage)
        _ = accumulator.add(sample(8, 18, false))
        _ = accumulator.add(sample(35, 18, false))
        let after = try #require(accumulator.flush()?.usage)
        #expect(before.acSeconds == 4 && after.acSeconds == 4)
        #expect(after.batterySeconds == 0 && after.energySeconds == 8)
        #expect(abs(before.dischargedWh - 0.01) < 0.000001)
        #expect(abs(after.chargedWh - 0.03) < 0.000001)
        #expect(before.chargedWh == 0 && after.dischargedWh == 0)
    }

    @Test func historicalContextIsOptionalAndTargetsKeepTransitions() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalActivityStore(directory: folder)
        let start = Date(timeIntervalSince1970: 1_800_000_000), session = UUID()
        let now = start.addingTimeInterval(360)
        for (i, target) in [nil, 80, 80, 80, 90, nil].enumerated() {
            var row = activityMinute(start.addingTimeInterval(Double(i * 60)), values: [.charge: Double(70 + i)], session: session)
            row.limit = target
            try await store.append(row, now: now)
        }
        let result = try await store.chartHistory(since: start, metric: .charge, now: now)
        #expect(result.targets.first?.timestamp == start.addingTimeInterval(60))
        #expect(result.targets.last?.value == 90)
        #expect(result.usage.energySeconds == 0 && result.sources.isEmpty)
        #expect(result.firstCharge == 70 && result.lastCharge == 75)
    }

    @Test func timelineKeepsOnlyRelevantEventsInsideSelectedPeriod() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalActivityStore(directory: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (seconds, code) in [(-30, "application.sleep"), (-10, "application.wake"), (-8, "application.started"), (-2, "charging.modeObserved")] {
            try await store.append(.init(at: now.addingTimeInterval(Double(seconds)), category: .application, code: code), now: now)
        }
        let snapshot = try await store.timeline(since: now.addingTimeInterval(-20), until: now)
        #expect(snapshot.events.map(\.code) == ["application.wake", "charging.modeObserved"])
    }

    @Test func lateMinuteCanFillMissingMetricButCannotRollBackDailyHealth() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalActivityStore(directory: folder)
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        let late = early.addingTimeInterval(120), now = late.addingTimeInterval(60)
        try await store.append(activityMinute(late, values: [.cycles: 102, .appleHealth: 98]), now: now)
        try await store.append(activityMinute(early, values: [.cycles: 100, .openDenteHealth: 92]), now: now)
        let snapshot = try await store.history(since: early, now: now)
        let day = try #require(snapshot.dailyHealth.first)
        #expect(day.cycleCount == 102 && day.cyclesObservedAt == late.addingTimeInterval(58))
        #expect(day.applePercentage == 98 && day.openDentePercentage == 92)
        #expect(day.lastObservedAt == late.addingTimeInterval(58))
    }

    @Test func pruningOnlyRemovesCanonicalPartitionFiles() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalActivityStore(directory: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.append(activityMinute(now, values: [.charge: 80]), now: now)
        let minutes = folder.appendingPathComponent("minutes")
        let names = ["2020-01-01.json", "2020-1-1.jsonl", "2020-01-02.jsonl"]
        for name in names { try Data().write(to: minutes.appendingPathComponent(name)) }
        try await store.prune(now: now)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: minutes.path)
        #expect(remaining.contains(names[0]) && remaining.contains(names[1]))
        #expect(!remaining.contains(names[2]))
    }

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

    @Test func dailyHealthUsesLatestObservedValuesAndTimestamps() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var accumulator = MinuteHistoryAccumulator()
        _ = accumulator.add(.init(timestamp: date, values: [.cycles: 100, .appleHealth: 99]))
        _ = accumulator.add(.init(timestamp: date.addingTimeInterval(30), values: [.cycles: 101, .appleHealth: 98]))
        _ = accumulator.add(.init(timestamp: date.addingTimeInterval(59), values: [.charge: 80]))
        let flushed = accumulator.flush()
        let minute = try #require(flushed)

        #expect(minute.value(.cycles) == 100.5)
        #expect(minute.value(.appleHealth) == 98.5)
        #expect(minute.lastObservedValue(.cycles) == 101)
        #expect(minute.lastObservedValue(.appleHealth) == 98)
        #expect(minute.metricLastObservedAt["cycles"] == date.addingTimeInterval(30))
        #expect(minute.metricLastObservedAt["appleHealth"] == date.addingTimeInterval(30))

        let store = LocalActivityStore(directory: folder)
        try await store.append(minute, now: date.addingTimeInterval(60))
        let snapshot = try await store.history(since: date.addingTimeInterval(-1), now: date.addingTimeInterval(120))
        let daily = try #require(snapshot.dailyHealth.first)
        #expect(daily.cycleCount == 101)
        #expect(daily.applePercentage == 98)
        #expect(daily.cyclesObservedAt == date.addingTimeInterval(30))
        #expect(daily.appleObservedAt == date.addingTimeInterval(30))
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

    @Test func legacyMinuteJSONOpensAndDoesNotReplaceDailyLatestValuesWithAverages() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let legacyJSON = Data("""
        {
          "schemaVersion": 1,
          "sessionID": "00000000-0000-0000-0000-000000000001",
          "timestamp": "2027-01-15T08:01:00Z",
          "firstObservedAt": "2027-01-15T08:01:00Z",
          "lastObservedAt": "2027-01-15T08:01:59Z",
          "readingCount": 2,
          "validChargeReadingCount": 0,
          "averages": {"cycles": 100.5, "appleHealth": 98.5},
          "valueCounts": {"cycles": 2, "appleHealth": 2},
          "metricLastObservedAt": {
            "cycles": "2027-01-15T08:01:58Z",
            "appleHealth": "2027-01-15T08:01:58Z"
          },
          "sources": {},
          "healthQualities": ["valid"]
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(BatteryHistoryMinute.self, from: legacyJSON)
        #expect(legacy.latestValues == nil)

        let store = LocalActivityStore(directory: folder)
        try await store.append(activityMinute(date, values: [.cycles: 102, .appleHealth: 96]), now: date)
        try await store.append(legacy, now: date.addingTimeInterval(120))
        let snapshot = try await store.history(since: date.addingTimeInterval(-1), now: date.addingTimeInterval(120))
        let daily = try #require(snapshot.dailyHealth.first)
        #expect(snapshot.minutes.count == 2)
        #expect(snapshot.damagedRecords == 0)
        #expect(daily.cycleCount == 102)
        #expect(daily.applePercentage == 96)
        #expect(daily.cyclesObservedAt == date.addingTimeInterval(58))
        #expect(daily.appleObservedAt == date.addingTimeInterval(58))
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

    @Test func partitionSeparatorCountsTowardLimitAndLegacyOverflowIsReadable() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let event = LocalActivityEvent(at: date, category: .application, code: "started")
        let store = LocalActivityStore(directory: folder)
        try await store.append(event, now: date)
        let url = try #require(FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("events"),
            includingPropertiesForKeys: nil).first)
        let line = try Data(contentsOf: url)
        let limit = LocalActivityStore.maximumPartitionBytes
        let truncated = Data(repeating: 120, count: limit - line.count)
        try truncated.write(to: url)
        await #expect(throws: LocalActivityStorageError.self) {
            try await store.append(event, deduplicateFor: 0, now: date)
        }
        #expect(try Data(contentsOf: url) == truncated)
        try Data(truncated.dropLast()).write(to: url)
        try await store.append(event, deduplicateFor: 0, now: date)
        #expect(try Data(contentsOf: url).count == limit)
        try (truncated + Data([10]) + line).write(to: url)
        let snapshot = try await store.events(now: date)
        #expect(snapshot.events.map(\.id) == [event.id])
        #expect(snapshot.damagedRecords == 1)
    }

    @Test func latestEventsSkipOlderPartitionsAndExportStillReadsAll() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LocalActivityStore(directory: folder)
        for offset in [-86_400, 0, -60] {
            let event = LocalActivityEvent(at: now.addingTimeInterval(Double(offset)), category: .application, code: "sample")
            try await store.append(event, deduplicateFor: 0, now: now)
        }
        let urls = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("events"),
            includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        let oldest = try #require(urls.first)
        try (Data(contentsOf: oldest) + Data("broken\n".utf8)).write(to: oldest)
        let limited = try await store.events(now: now, maximum: 2)
        let all = try await store.events(now: now, maximum: nil)
        #expect(limited.events.map(\.id) == all.events.prefix(2).map(\.id))
        #expect(limited.damagedRecords == 0 && all.damagedRecords == 1)
        let data = try await store.exportEvents(now: now)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["events"] as? [Any])?.count == 3)
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
        let destination = folder.appendingPathComponent("export.json")
        try await store.exportHistory(to: destination, now: date.addingTimeInterval(60))
        let exported = try Data(contentsOf: destination)
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("systemProfiler"))
        #expect(text.contains("ioRegistry"))
        #expect(text.contains("valid"))
        #expect(text.contains("appleHealth"))
        #expect(text.contains("openDenteHealth"))
        #expect(!text.contains("PRIVATE-ADAPTER-SERIAL"))
        #expect(!text.contains("serial"))
    }

    @Test func chartAndExportPreserveMidnightContinuityAndDamagedCount() async throws {
        let directory = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalActivityStore(directory: directory)
        let midnight = LocalActivityStore.day(Date())
        let session = UUID()
        for offset in [-60, 120, 60, 0] {
            let date = midnight.addingTimeInterval(Double(offset))
            let values: [HistoryMetric: Double] = offset == 60 ? [.temperature: 32] : [.charge: Double(70 + offset / 60)]
            try await store.append(activityMinute(date, values: values, session: session), now: midnight)
        }
        let minuteDirectory = directory.appendingPathComponent("minutes")
        let file = try #require(FileManager.default.contentsOfDirectory(at: minuteDirectory,
            includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.last)
        try (Data(contentsOf: file) + Data("bad\n".utf8)).write(to: file)
        let end = midnight.addingTimeInterval(180)
        let chart = try await store.chartHistory(since: midnight.addingTimeInterval(-60), metric: .charge, now: end)
        #expect(chart.points.map(\.segment) == [0, 0, 1])
        #expect(chart.points.map(\.value) == [69, 70, 72])
        #expect(chart.damagedRecords == 1)
        struct Export: Decodable {
            let minutes: [BatteryHistoryMinute]
            let dailyHealth: [DailyBatteryHealth]
            let damagedRecords: Int
            let exportedAt: Date
            let timezone: String
            let schemaVersion: Int
        }
        let url = directory.appendingPathComponent("export.json")
        try await store.exportHistory(to: url, now: end)
        let contents = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Export.self, from: contents)
        #expect(result.minutes.map(\.timestamp) == [-60, 0, 60, 120].map { midnight.addingTimeInterval(Double($0)) })
        #expect(result.dailyHealth == chart.dailyHealth && result.damagedRecords == 1)
        #expect(result.exportedAt == end && result.timezone == "UTC" && result.schemaVersion == 1)
        try Data(repeating: 32, count: LocalActivityStore.maximumPartitionBytes + 2).write(to: file)
        await #expect(throws: LocalActivityStorageError.self) { try await store.exportHistory(to: url, now: end) }
        #expect(try Data(contentsOf: url) == contents)
    }

    @MainActor @Test func recordingEventsLeavesHistoryRevisionUnchanged() async throws {
        let folder = temporaryActivityDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = LocalActivityRecorder(store: LocalActivityStore(directory: folder))
        recorder.record(.init(category: .application, code: "sample"))
        await recorder.flush()
        #expect(recorder.eventRevision == 1 && recorder.historyRevision == 0)
        try await recorder.clearHistory()
        #expect(recorder.eventRevision == 1 && recorder.historyRevision == 1)
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
