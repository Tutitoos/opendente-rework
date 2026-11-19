import Foundation

enum LocalActivityStorageError: Error, LocalizedError {
    case partitionTooLarge
    case invalidDirectory
    var errorDescription: String? {
        switch self {
        case .partitionTooLarge: "A local activity file exceeded its size limit. Export or clear the affected history."
        case .invalidDirectory: "The local activity directory is unavailable."
        }
    }
}

struct LocalHistorySnapshot: Sendable {
    let minutes: [BatteryHistoryMinute]
    let dailyHealth: [DailyBatteryHealth]
    let damagedRecords: Int
}
struct LocalEventsSnapshot: Sendable {
    let events: [LocalActivityEvent]
    let damagedRecords: Int
}

struct ActivityChartHistory: Sendable {
    var points: [HistoryPlotPoint] = []
    var power: [HistoryPlotPoint] = []
    var targets: [HistoryPlotPoint] = []
    var sources: [Date: Bool] = [:]
    var usage = BatteryUsage()
    var firstCharge: Double?
    var lastCharge: Double?
    var dailyHealth: [DailyBatteryHealth] = []
    var damagedRecords = 0
}

/// Small daily append-only partitions avoid rewriting the retained history on each poll.
/// The actor owns file handles and serializes append/query/delete operations.
actor LocalActivityStore {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenDente/Activity", isDirectory: true)
    static let eventDisplayLimit = 2_000
    static let maximumPartitionBytes = 8 * 1_024 * 1_024

    private let directory: URL
    private let files: FileManager
    private var retention: LocalActivityRetention
    private var lastPrunedDay: Date?
    private var lastEvent: LocalActivityEvent?
    private var healthCache: [String: DailyBatteryHealth] = [:]
    private var isPrepared = false

    // Initialization does not create directories or touch production data.
    init(directory: URL = LocalActivityStore.defaultDirectory, retention: LocalActivityRetention = .init(),
         files: FileManager = .default) {
        self.directory = directory
        self.retention = retention.validated
        self.files = files
    }

    func append(_ minute: BatteryHistoryMinute, now: Date = Date()) throws {
        try prepare()
        try pruneIfNeeded(now: now)
        let day = Self.day(minute.timestamp)
        let key = Self.dayKey(day)
        let previous = try healthCache[key] ?? readHealth(at: day)
        try appendLine(minute, to: partition("minutes", at: minute.timestamp))
        let summary = DailyBatteryHealth.merging(minute, with: previous)
        healthCache = [key: summary]
        let data = try Self.encoder().encode(summary)
        try data.write(to: healthURL(day), options: .atomic)
    }

    @discardableResult
    func append(_ event: LocalActivityEvent, deduplicateFor seconds: TimeInterval = 30,
                now: Date = Date()) throws -> Bool {
        try prepare()
        try pruneIfNeeded(now: now)
        if let previous = lastEvent, previous.deduplicationKey == event.deduplicationKey,
           event.timestamp.timeIntervalSince(previous.timestamp) >= 0,
           event.timestamp.timeIntervalSince(previous.timestamp) < seconds { return false }
        try appendLine(event, to: partition("events", at: event.timestamp))
        lastEvent = event
        return true
    }

    func setRetention(_ value: LocalActivityRetention, now: Date = Date()) throws {
        retention = value.validated
        guard isPrepared || files.fileExists(atPath: directory.path) else { return }
        try prune(now: now)
    }

    func history(since: Date, now: Date = Date()) throws -> LocalHistorySnapshot {
        var minutes: [BatteryHistoryMinute] = []
        let damaged = try visitMinutes(since: since, now: now) { minutes.append(contentsOf: $0) }
        let health = try dailyHealth(now: now)
        return .init(minutes: minutes, dailyHealth: health.rows, damagedRecords: damaged + health.damaged)
    }

    func chartHistory(since: Date, metric: HistoryMetric, now: Date = Date()) throws
        -> ActivityChartHistory {
        var result = ActivityChartHistory()
        var series = HistoryPlot.MinuteSeries(), power = HistoryPlot.MinuteSeries(), targets = HistoryPlot.MinuteSeries()
        result.damagedRecords = try visitMinutes(since: since, now: now) { rows in
            series.append(rows, metric: metric)
            if metric == .charge {
                power.append(rows, metric: .batteryPower)
                targets.append(rows) { $0.limit.map(Double.init) }
            }
            for row in rows {
                if let usage = row.usage { result.usage.add(usage) }
                result.sources[row.timestamp] = row.onAC
                if result.firstCharge == nil { result.firstCharge = row.initialCharge ?? row.value(.charge) }
                if let charge = row.lastObservedValue(.charge) ?? row.value(.charge) { result.lastCharge = charge }
            }
        }
        result.points = series.points
        result.power = power.points
        // Keep both ends of every constant run so step changes stay at the recorded minute.
        let points = targets.points
        result.targets = points.indices.compactMap { i in
            if i > 0, i + 1 < points.count, points[i-1].segment == points[i+1].segment,
               points[i-1].value == points[i].value, points[i].value == points[i+1].value { return nil }
            return points[i]
        }
        let health = try dailyHealth(now: now)
        result.dailyHealth = health.rows
        result.damagedRecords += health.damaged
        return result
    }

    func timeline(since: Date, until: Date) throws -> LocalEventsSnapshot {
        var result: [LocalActivityEvent] = []
        var damaged = 0
        let start = max(since, until.addingTimeInterval(-Double(retention.eventDays) * 86400))
        for url in try partitions("events", since: start, until: until) {
            try Task.checkCancellation()
            let (rows, skipped): ([LocalActivityEvent], Int) = try readPartition(url)
            damaged += skipped
            result += rows.filter { event in
                (start...until).contains(event.timestamp) && (event.category == .monthlyCharge ||
                    ["charging.modeObserved", "charging.telemetryObserved", "charging.sourceChanged", "charging.targetChanged",
                     "application.sleep", "application.wake", "native.limitConfirmed"].contains(event.code))
            }
        }
        return .init(events: result.sorted { $0.timestamp < $1.timestamp }, damagedRecords: damaged)
    }

    private func dailyHealth(now: Date) throws -> (rows: [DailyBatteryHealth], damaged: Int) {
        var health: [DailyBatteryHealth] = []
        var damaged = 0
        let healthCutoff = Self.day(now.addingTimeInterval(-Double(retention.healthDays) * 86400))
        for url in try urls(in: "health") where Self.dateKey(url).map({ $0 >= healthCutoff }) ?? false {
            do { health.append(try Self.decoder().decode(DailyBatteryHealth.self, from: boundedData(url))) }
            catch DecodingError.dataCorrupted { damaged += 1 }
            catch is DecodingError { damaged += 1 }
        }
        return (health.filter { $0.day <= now }.sorted { $0.day < $1.day }, damaged)
    }

    func events(now: Date = Date(), maximum: Int? = LocalActivityStore.eventDisplayLimit) throws -> LocalEventsSnapshot {
        guard files.fileExists(atPath: directory.path) else { return .init(events: [], damagedRecords: 0) }
        let earliest = now.addingTimeInterval(-Double(retention.eventDays) * 86400)
        var events: [LocalActivityEvent] = []
        var damaged = 0
        let limit = max(0, maximum ?? Int.max)
        let partitions = try partitions("events", since: earliest, until: now)
        for url in partitions.reversed() {
            if events.count >= limit { break }
            let (rows, skipped): ([LocalActivityEvent], Int) = try readPartition(url)
            damaged += skipped
            let day = rows.filter { $0.timestamp >= earliest && $0.timestamp <= now }
                .sorted { $0.timestamp > $1.timestamp }
            events.append(contentsOf: day.prefix(limit - events.count))
        }
        return .init(events: events, damagedRecords: damaged)
    }

    func exportHistory(to destination: URL, now: Date = Date()) throws {
        let scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent("history.json")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        let encoder = Self.encoder()
        try output.write(contentsOf: Data(#"{"schemaVersion":1,"timezone":"UTC","exportedAt":"#.utf8))
        try output.write(contentsOf: encoder.encode(now))
        try output.write(contentsOf: Data(#","minutes":["#.utf8))
        var first = true
        let damaged = try visitMinutes(since: .distantPast, now: now) { rows in
            var buffer = Data()
            for row in rows {
                if !first { buffer.append(0x2C) } // Comma between records, including across partitions.
                buffer.append(0x0A)
                buffer.append(try encoder.encode(row))
                first = false
            }
            try output.write(contentsOf: buffer)
        }
        let health = try dailyHealth(now: now)
        try output.write(contentsOf: Data(#"],"dailyHealth":"#.utf8))
        try output.write(contentsOf: encoder.encode(health.rows))
        try output.write(contentsOf: Data(",\"damagedRecords\":\(damaged + health.damaged)}".utf8))
        try output.close()
        try Task.checkCancellation()
        // The replacement directory is on the destination volume, so rename commits atomically.
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func exportEvents(now: Date = Date()) throws -> Data {
        let snapshot = try events(now: now, maximum: nil)
        struct Export: Encodable {
            let schemaVersion = 1
            let exportedAt: Date
            let timezone = "UTC"
            let events: [LocalActivityEvent]
            let damagedRecords: Int
        }
        return try Self.encoder(pretty: true).encode(Export(exportedAt: now, events: snapshot.events,
                                                          damagedRecords: snapshot.damagedRecords))
    }

    func clearHistory() throws {
        try removeFolder("minutes")
        try removeFolder("health")
        healthCache.removeAll()
        isPrepared = false
    }

    func clearEvents() throws {
        try removeFolder("events")
        lastEvent = nil
        isPrepared = false
    }

    func prune(now: Date = Date()) throws {
        guard files.fileExists(atPath: directory.path) else { return }
        for (folder, days) in [("minutes", retention.minuteDays), ("events", retention.eventDays), ("health", retention.healthDays)] {
            let cutoff = Self.day(now.addingTimeInterval(-Double(days) * 86400))
            for url in try urls(in: folder) {
                // Unknown names are preserved rather than deleting unrelated files.
                if let date = Self.dateKey(url), date < cutoff { try files.removeItem(at: url) }
            }
        }
        lastPrunedDay = Self.day(now)
    }

    private func prepare() throws {
        guard !isPrepared else { return }
        for folder in [directory, directory.appendingPathComponent("minutes"),
                       directory.appendingPathComponent("events"), directory.appendingPathComponent("health")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        isPrepared = true
    }

    private func pruneIfNeeded(now: Date) throws {
        if lastPrunedDay != Self.day(now) { try prune(now: now) }
    }

    private func removeFolder(_ name: String) throws {
        let url = directory.appendingPathComponent(name)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    private func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try Self.encoder().encode(value)
        data.append(10)
        if !files.fileExists(atPath: url.path) {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LocalActivityStorageError.invalidDirectory
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // Isolate a crash-truncated final record before appending valid new records.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let tail = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if tail?.first != 10 { data.insert(10, at: 0) }
        }
        guard end + UInt64(data.count) <= UInt64(Self.maximumPartitionBytes) else {
            throw LocalActivityStorageError.partitionTooLarge
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func visitMinutes(since: Date, now: Date, _ visit: ([BatteryHistoryMinute]) throws -> Void) throws -> Int {
        let earliest = max(since, now.addingTimeInterval(-Double(retention.minuteDays) * 86400))
        var damaged = 0
        try Task.checkCancellation()
        for url in try partitions("minutes", since: earliest, until: now) {
            try Task.checkCancellation()
            try autoreleasepool {
                let (rows, skipped): ([BatteryHistoryMinute], Int) = try readPartition(url)
                damaged += skipped
                let ordered = rows.filter { $0.timestamp >= earliest && $0.timestamp <= now }
                    .sorted { $0.firstObservedAt < $1.firstObservedAt }
                try visit(ordered)
            }
        }
        return damaged
    }

    private func partitions(_ folder: String, since: Date, until: Date) throws -> [URL] {
        guard since <= until else { return [] }
        let days = Self.day(since)...Self.day(until)
        return try urls(in: folder).filter { Self.dateKey($0).map(days.contains) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readPartition<T: Decodable>(_ url: URL) throws -> ([T], Int) {
        var rows: [T] = []
        var damaged = 0
        let decoder = Self.decoder()
        // Older writers could exceed the limit by one newline after a truncated record.
        for line in try boundedData(url, limit: Self.maximumPartitionBytes + 1).split(separator: 10) {
            do { rows.append(try decoder.decode(T.self, from: Data(line))) }
            catch { damaged += 1 }
        }
        return (rows, damaged)
    }

    private func boundedData(_ url: URL, limit: Int = LocalActivityStore.maximumPartitionBytes) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw LocalActivityStorageError.partitionTooLarge }
        return try Data(contentsOf: url)
    }
    private func urls(in folder: String) throws -> [URL] {
        let url = directory.appendingPathComponent(folder)
        guard files.fileExists(atPath: url.path) else { return [] }
        return try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == (folder == "health" ? "json" : "jsonl") }
    }
    private func readHealth(at day: Date) throws -> DailyBatteryHealth? {
        let url = healthURL(day)
        guard files.fileExists(atPath: url.path) else { return nil }
        do { return try Self.decoder().decode(DailyBatteryHealth.self, from: boundedData(url)) }
        catch is DecodingError { return nil }
    }
    private func partition(_ folder: String, at date: Date) -> URL {
        directory.appendingPathComponent(folder).appendingPathComponent(Self.dayKey(date) + ".jsonl")
    }
    private func healthURL(_ day: Date) -> URL {
        directory.appendingPathComponent("health").appendingPathComponent(Self.dayKey(day) + ".json")
    }
    private static func dateKey(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let date = dayFormatter.date(from: name), dayKey(date) == name else { return nil }
        return date
    }
    private static func dayKey(_ day: Date) -> String { dayFormatter.string(from: day) }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func day(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 86400) * 86400)
    }
    private static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
