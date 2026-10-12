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

/// Small daily append-only partitions avoid rewriting the retained history on each poll.
/// The actor owns file handles and serializes append/query/delete operations.
actor LocalActivityStore {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenDente/Activity", isDirectory: true)
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
        try appendLine(minute, to: partition("minutes", at: minute.timestamp))
        let day = Self.day(minute.timestamp)
        let key = Self.dayKey(day)
        let previous = try healthCache[key] ?? readHealth(at: day)
        let summary = DailyBatteryHealth(day: day, lastObservedAt: minute.lastObservedAt,
            applePercentage: minute.value(.appleHealth) ?? previous?.applePercentage,
            openDentePercentage: minute.value(.openDenteHealth) ?? previous?.openDentePercentage,
            cycleCount: minute.value(.cycles) ?? previous?.cycleCount,
            appleObservedAt: minute.metricLastObservedAt["appleHealth"] ?? previous?.appleObservedAt,
            openDenteObservedAt: minute.metricLastObservedAt["openDenteHealth"] ?? previous?.openDenteObservedAt,
            cyclesObservedAt: minute.metricLastObservedAt["cycles"] ?? previous?.cyclesObservedAt,
            sources: (previous?.sources ?? [:]).merging(minute.sources.filter {
                ["appleHealth", "openDenteHealth", "cycles"].contains($0.key)
            }, uniquingKeysWith: { _, new in new }),
            quality: Array(Set((previous?.quality ?? []) + minute.healthQualities)).sorted())
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
        guard files.fileExists(atPath: directory.path) else {
            return .init(minutes: [], dailyHealth: [], damagedRecords: 0)
        }
        let earliest = max(since, now.addingTimeInterval(-Double(retention.minuteDays) * 86400))
        let minuteResult: ([BatteryHistoryMinute], Int) = try readLines("minutes", since: earliest, until: now)
        var health: [DailyBatteryHealth] = []
        var damaged = minuteResult.1
        let healthCutoff = Self.day(now.addingTimeInterval(-Double(retention.healthDays) * 86400))
        for url in try urls(in: "health") where Self.dateKey(url).map({ $0 >= healthCutoff }) ?? false {
            do { health.append(try Self.decoder().decode(DailyBatteryHealth.self, from: boundedData(url))) }
            catch DecodingError.dataCorrupted { damaged += 1 }
            catch is DecodingError { damaged += 1 }
        }
        return .init(minutes: minuteResult.0.filter { $0.timestamp >= earliest && $0.timestamp <= now }
            .sorted { $0.firstObservedAt < $1.firstObservedAt },
            dailyHealth: health.filter { $0.day <= now }.sorted { $0.day < $1.day }, damagedRecords: damaged)
    }

    func events(now: Date = Date(), maximum: Int? = 2_000) throws -> LocalEventsSnapshot {
        guard files.fileExists(atPath: directory.path) else { return .init(events: [], damagedRecords: 0) }
        let earliest = now.addingTimeInterval(-Double(retention.eventDays) * 86400)
        let result: ([LocalActivityEvent], Int) = try readLines("events", since: earliest, until: now)
        let sorted = result.0.filter { $0.timestamp >= earliest && $0.timestamp <= now }.sorted { $0.timestamp > $1.timestamp }
        return .init(events: maximum.map { Array(sorted.prefix(max(0, $0))) } ?? sorted, damagedRecords: result.1)
    }

    func exportHistory(now: Date = Date()) throws -> Data {
        let snapshot = try history(since: now.addingTimeInterval(-Double(retention.minuteDays) * 86400), now: now)
        struct Export: Encodable {
            let schemaVersion = 1
            let exportedAt: Date
            let timezone = "UTC"
            let minutes: [BatteryHistoryMinute]
            let dailyHealth: [DailyBatteryHealth]
            let damagedRecords: Int
        }
        return try Self.encoder(pretty: true).encode(Export(exportedAt: now, minutes: snapshot.minutes,
            dailyHealth: snapshot.dailyHealth, damagedRecords: snapshot.damagedRecords))
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
        guard end + UInt64(data.count) <= UInt64(Self.maximumPartitionBytes) else {
            throw LocalActivityStorageError.partitionTooLarge
        }
        // Isolate a crash-truncated final record before appending valid new records.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let tail = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if tail?.first != 10 { try handle.write(contentsOf: Data([10])) }
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func readLines<T: Decodable>(_ folder: String, since: Date, until: Date) throws -> ([T], Int) {
        var values: [T] = []
        var damaged = 0
        let decoder = Self.decoder()
        for url in try urls(in: folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let day = Self.dateKey(url), day >= Self.day(since), day <= Self.day(until) else { continue }
            for line in try boundedData(url).split(separator: 10) {
                do { values.append(try decoder.decode(T.self, from: Data(line))) }
                catch { damaged += 1 }
            }
        }
        return (values, damaged)
    }

    private func boundedData(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumPartitionBytes else { throw LocalActivityStorageError.partitionTooLarge }
        return try Data(contentsOf: url)
    }
    private func urls(in folder: String) throws -> [URL] {
        let url = directory.appendingPathComponent(folder)
        guard files.fileExists(atPath: url.path) else { return [] }
        return try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
            .filter { ["json", "jsonl"].contains($0.pathExtension) }
    }
    private func readHealth(at day: Date) throws -> DailyBatteryHealth? {
        let url = healthURL(day)
        guard files.fileExists(atPath: url.path) else { return nil }
        return try? Self.decoder().decode(DailyBatteryHealth.self, from: boundedData(url))
    }
    private func partition(_ folder: String, at date: Date) -> URL {
        directory.appendingPathComponent(folder).appendingPathComponent(Self.dayKey(date) + ".jsonl")
    }
    private func healthURL(_ day: Date) -> URL {
        directory.appendingPathComponent("health").appendingPathComponent(Self.dayKey(day) + ".json")
    }
    private static func dateKey(_ url: URL) -> Date? {
        let formatter = dayFormatter()
        return formatter.date(from: url.deletingPathExtension().lastPathComponent)
    }
    private static func dayKey(_ day: Date) -> String { dayFormatter().string(from: day) }
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
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
