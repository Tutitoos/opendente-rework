import Foundation

enum HistoryMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case charge, temperature, batteryPower, adapterPower, systemPower, cycles, appleHealth, openDenteHealth
    var id: String { rawValue }
}

/// Persisted readings contain no adapter identity, serial number or network information.
struct BatteryHistoryReading: Sendable {
    let timestamp: Date
    let values: [HistoryMetric: Double]
    let sources: [String: String]
    let chargeValid: Bool
    let healthQuality: String

    var onAC: Bool?
    var limit: Int?

    init(state: BatteryState, at timestamp: Date, limit: Int? = nil) {
        self.limit = limit
        onAC = state.hasValidBatteryReading ? state.isPluggedIn : nil
        self.timestamp = timestamp
        var values: [HistoryMetric: Double] = [:]
        let validCharge = state.hasValidBatteryReading && (0...100).contains(state.percentage)
        if validCharge { values[.charge] = Double(state.percentage) }
        if let v = state.temperature, v.isFinite, (-20...100).contains(v) { values[.temperature] = v }
        for (metric, value) in [(HistoryMetric.batteryPower, state.batteryPower),
                                (.adapterPower, state.adapterPower), (.systemPower, state.systemPower)] {
            if let v = value, v.isFinite, abs(v) <= 500,
               metric == .batteryPower || v >= 0 { values[metric] = v }
        }
        if let v = state.cycleCount, (0...20_000).contains(v) { values[.cycles] = Double(v) }
        if let v = state.systemMaximumCapacityPercentage, (0...100).contains(v),
           state.systemMaximumCapacitySource != .unavailable { values[.appleHealth] = Double(v) }
        if state.healthDataQuality == .valid, let v = state.healthPercentage, v.isFinite {
            values[.openDenteHealth] = v
        }
        self.values = values
        chargeValid = validCharge
        healthQuality = state.healthDataQuality.rawValue
        sources = ["charge": BatteryDataSource.iops.rawValue, "temperature": "smc",
                   "batteryPower": "smc", "adapterPower": "smc", "systemPower": "smc",
                   "cycles": "BatteryService: SMC/IORegistry/IOPS",
                   "appleHealth": state.systemMaximumCapacitySource.rawValue,
                   "openDenteHealth": state.capacitySource.rawValue]
            .filter { key, _ in HistoryMetric(rawValue: key).map { values[$0] != nil } ?? false }
    }

    init(timestamp: Date, values: [HistoryMetric: Double], sources: [String: String] = [:],
         chargeValid: Bool = true, healthQuality: String = "valid") {
        self.timestamp = timestamp
        self.values = values.filter { $0.value.isFinite }
        self.sources = sources
        self.chargeValid = chargeValid
        self.healthQuality = healthQuality
    }
}

struct BatteryUsage: Codable, Equatable, Sendable {
    var acSeconds = 0.0, batterySeconds = 0.0, energySeconds = 0.0
    var chargedWh = 0.0, dischargedWh = 0.0

    mutating func add(_ other: Self) {
        acSeconds += other.acSeconds
        batterySeconds += other.batterySeconds
        energySeconds += other.energySeconds
        chargedWh += other.chargedWh
        dischargedWh += other.dischargedWh
    }

    mutating func integrate(_ a: BatteryHistoryReading, _ b: BatteryHistoryReading, from: Date, to: Date) {
        let span = b.timestamp.timeIntervalSince(a.timestamp), seconds = to.timeIntervalSince(from)
        guard span > 0, span <= 15, seconds > 0, a.chargeValid, b.chargeValid else { return }
        if let ac = a.onAC, ac == b.onAC {
            if ac { acSeconds += seconds } else { batterySeconds += seconds }
        }
        guard let start = a.values[.batteryPower], let end = b.values[.batteryPower] else { return }
        let slope = (end - start) / span
        let x = start + slope * from.timeIntervalSince(a.timestamp)
        let y = start + slope * to.timeIntervalSince(a.timestamp)
        energySeconds += seconds
        let hours = seconds / 3600
        if x * y < 0 {
            let peak = max(x, y), trough = -min(x, y)
            chargedWh += hours * peak * peak / (2 * (peak + trough))
            dischargedWh += hours * trough * trough / (2 * (peak + trough))
        } else {
            let wh = hours * (x + y) / 2
            chargedWh += max(0, wh)
            dischargedWh += max(0, -wh)
        }
    }
}

struct BatteryHistoryMinute: Codable, Identifiable, Equatable, Sendable {
    var usage: BatteryUsage?
    var onAC: Bool?
    var limit: Int?
    var initialCharge: Double?
    let schemaVersion: Int
    let sessionID: UUID
    let timestamp: Date
    let firstObservedAt: Date
    let lastObservedAt: Date
    let readingCount: Int
    let validChargeReadingCount: Int
    let averages: [String: Double]
    let latestValues: [String: Double]?
    let valueCounts: [String: Int]
    let metricLastObservedAt: [String: Date]
    let sources: [String: [String]]
    let healthQualities: [String]
    var id: String { "\(sessionID.uuidString)-\(firstObservedAt.timeIntervalSince1970)-\(lastObservedAt.timeIntervalSince1970)" }
    func value(_ metric: HistoryMetric) -> Double? { averages[metric.rawValue] }
    func lastObservedValue(_ metric: HistoryMetric) -> Double? { latestValues?[metric.rawValue] }

    init(schemaVersion: Int, sessionID: UUID, timestamp: Date, firstObservedAt: Date,
         lastObservedAt: Date, readingCount: Int, validChargeReadingCount: Int,
         averages: [String: Double], valueCounts: [String: Int], metricLastObservedAt: [String: Date],
         sources: [String: [String]], healthQualities: [String], latestValues: [String: Double]? = nil) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.readingCount = readingCount
        self.validChargeReadingCount = validChargeReadingCount
        self.averages = averages
        self.latestValues = latestValues
        self.valueCounts = valueCounts
        self.metricLastObservedAt = metricLastObservedAt
        self.sources = sources
        self.healthQualities = healthQualities
    }
}

/// One minute is written once. A long pause creates a new minute, never synthetic samples.
struct MinuteHistoryAccumulator {
    private var firstObservedAt: Date?
    private var initialCharge: Double?
    private var last: BatteryHistoryReading?
    private var readingCount = 0
    private var validChargeCount = 0
    private var sums: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var latestValues: [String: Double] = [:]
    private var sources: [String: Set<String>] = [:]
    private var metricTimes: [String: Date] = [:]
    private var qualities: Set<String> = []
    private var usage = BatteryUsage()
    private let sessionID: UUID
    init(sessionID: UUID = UUID()) { self.sessionID = sessionID }

    mutating func add(_ reading: BatteryHistoryReading) -> BatteryHistoryMinute? {
        let bucket = Self.minute(reading.timestamp)
        let previous = last
        let changed = previous.map { Self.minute($0.timestamp) != bucket } ?? false
        if let previous {
            usage.integrate(previous, reading, from: previous.timestamp, to: changed ? bucket : reading.timestamp)
        }
        let flushed = changed ? flush() : nil
        if changed, let previous {
            usage.integrate(previous, reading, from: bucket, to: reading.timestamp)
        }
        if firstObservedAt == nil { firstObservedAt = reading.timestamp }
        if initialCharge == nil { initialCharge = reading.values[.charge] }
        last = reading
        readingCount += 1
        if reading.chargeValid { validChargeCount += 1 }
        qualities.insert(reading.healthQuality)
        for (metric, value) in reading.values {
            let key = metric.rawValue
            sums[key, default: 0] += value
            counts[key, default: 0] += 1
            latestValues[key] = value
            metricTimes[key] = reading.timestamp
            if let source = reading.sources[key] { sources[key, default: []].insert(source) }
        }
        return flushed
    }

    mutating func flush() -> BatteryHistoryMinute? {
        guard let firstObservedAt, let last else { return nil }
        var result = BatteryHistoryMinute(schemaVersion: 1, sessionID: sessionID,
            timestamp: Self.minute(firstObservedAt), firstObservedAt: firstObservedAt,
            lastObservedAt: last.timestamp, readingCount: readingCount,
            validChargeReadingCount: validChargeCount,
            averages: sums.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value / Double(counts[entry.key, default: 1])
            }, valueCounts: counts, metricLastObservedAt: metricTimes, sources: sources.mapValues { $0.sorted() },
            healthQualities: qualities.sorted(), latestValues: latestValues)
        result.usage = usage
        result.initialCharge = initialCharge
        result.onAC = last.onAC
        result.limit = last.limit
        self = Self(sessionID: sessionID)
        return result
    }

    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}

struct DailyBatteryHealth: Codable, Identifiable, Equatable, Sendable {
    let day: Date
    let lastObservedAt: Date
    let applePercentage: Double?
    let openDentePercentage: Double?
    let cycleCount: Double?
    let appleObservedAt: Date?
    let openDenteObservedAt: Date?
    let cyclesObservedAt: Date?
    let sources: [String: [String]]
    let quality: [String]
    var id: Date { day }

    static func merging(_ minute: BatteryHistoryMinute, with previous: Self?) -> Self {
        var sources = previous?.sources ?? [:]
        func latest(_ metric: HistoryMetric, oldValue: Double?, observedAt: Date?) -> (Double?, Date?) {
            guard let value = minute.lastObservedValue(metric) else { return (oldValue, observedAt) }
            let timestamp = minute.metricLastObservedAt[metric.rawValue] ?? minute.lastObservedAt
            if oldValue != nil, let oldTime = observedAt ?? previous?.lastObservedAt, timestamp < oldTime {
                return (oldValue, observedAt)
            }
            sources[metric.rawValue] = minute.sources[metric.rawValue]
            return (value, timestamp)
        }
        let apple = latest(.appleHealth, oldValue: previous?.applePercentage, observedAt: previous?.appleObservedAt)
        let capacity = latest(.openDenteHealth, oldValue: previous?.openDentePercentage, observedAt: previous?.openDenteObservedAt)
        let cycles = latest(.cycles, oldValue: previous?.cycleCount, observedAt: previous?.cyclesObservedAt)
        return Self(day: LocalActivityStore.day(minute.timestamp),
                    lastObservedAt: max(previous?.lastObservedAt ?? minute.lastObservedAt, minute.lastObservedAt),
                    applePercentage: apple.0, openDentePercentage: capacity.0, cycleCount: cycles.0,
                    appleObservedAt: apple.1, openDenteObservedAt: capacity.1, cyclesObservedAt: cycles.1,
                    sources: sources, quality: Set((previous?.quality ?? []) + minute.healthQualities).sorted())
    }
}

struct HistoryPlotPoint: Identifiable, Sendable {
    let timestamp: Date
    let value: Double
    let segment: Int
    var id: String { "\(segment)-\(timestamp.timeIntervalSince1970)" }
}

enum HistoryPlot {
    /// Missing metric values, separate sessions and pauses split the series.
    static func points(_ rows: [BatteryHistoryMinute], metric: HistoryMetric,
                       maximumPoints: Int = 1_500) -> [HistoryPlotPoint] {
        var series = MinuteSeries()
        series.append(rows.sorted { $0.firstObservedAt < $1.firstObservedAt }, metric: metric)
        return downsample(series.points, maximumPoints: maximumPoints)
    }

    struct MinuteSeries {
        private(set) var points: [HistoryPlotPoint] = []
        private var segment = -1
        private var previous: BatteryHistoryMinute?
        private var broken = true

        mutating func append(_ orderedRows: [BatteryHistoryMinute], metric: HistoryMetric) {
            append(orderedRows) { $0.value(metric) }
        }

        mutating func append(_ orderedRows: [BatteryHistoryMinute], valueFor: (BatteryHistoryMinute) -> Double?) {
            for row in orderedRows {
                guard let value = valueFor(row), value.isFinite else { broken = true; continue }
                let gap = previous.map { row.firstObservedAt.timeIntervalSince($0.lastObservedAt) > 15
                    || row.firstObservedAt < $0.lastObservedAt || row.sessionID != $0.sessionID } ?? true
                if broken || gap { segment += 1 }
                points.append(.init(timestamp: row.timestamp, value: value, segment: segment))
                previous = row
                broken = false
            }
        }
    }

    static func downsample(_ points: [HistoryPlotPoint], maximumPoints: Int = 1_500) -> [HistoryPlotPoint] {
        guard points.count > max(1, maximumPoints) else { return points }
        let width = Int(ceil(Double(points.count) / Double(max(1, maximumPoints / 2))))
        var result: [HistoryPlotPoint] = []
        var start = 0
        while start < points.count {
            var end = start + 1
            var low = start, high = start
            while end < points.count, end - start < width, points[end].segment == points[start].segment {
                if points[end].value < points[low].value { low = end }
                if points[end].value > points[high].value { high = end }
                end += 1
            }
            let first = min(low, high), last = max(low, high)
            if start == 0 || points[start - 1].segment != points[start].segment, first != start {
                result.append(points[start])
            }
            result.append(points[first])
            if last != first { result.append(points[last]) }
            if end == points.count || points[end].segment != points[start].segment, last != end - 1 {
                result.append(points[end - 1])
            }
            start = end
        }
        return result
    }

    static func dailyPoints(_ rows: [DailyBatteryHealth], metric: HistoryMetric) -> [HistoryPlotPoint] {
        var result: [HistoryPlotPoint] = []
        var previous: Date?
        var segment = 0
        for row in rows.sorted(by: { $0.day < $1.day }) {
            let value: Double? = switch metric {
            case .appleHealth: row.applePercentage
            case .openDenteHealth: row.openDentePercentage
            case .cycles: row.cycleCount
            default: nil
            }
            guard let value, value.isFinite else { previous = nil; continue }
            if previous.map({ row.day.timeIntervalSince($0) > 36 * 3600 }) ?? true { segment += 1 }
            result.append(.init(timestamp: row.day, value: value, segment: segment))
            previous = row.day
        }
        return result
    }
}

enum ActivityCategory: String, CaseIterable, Codable, Sendable {
    case charging, nativePolicy, monthlyCharge, helper, application
}
enum ActivitySeverity: String, CaseIterable, Codable, Sendable { case info, warning, error }

struct LocalActivityEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: ActivityCategory
    let severity: ActivitySeverity
    let code: String
    let values: [String: String]

    init(at timestamp: Date = Date(), category: ActivityCategory, severity: ActivitySeverity = .info,
         code: String, values: [String: String] = [:]) {
        id = UUID()
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.code = String(code.prefix(120))
        // Keep diagnostic values bounded; callers never supply adapter identities or serials.
        self.values = values.mapValues { String($0.prefix(2_048)) }
    }

    var deduplicationKey: String {
        "\(category.rawValue):\(severity.rawValue):\(code):" + values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: ";")
    }

    func matches(category: ActivityCategory?, severity: ActivitySeverity?, search: String) -> Bool {
        if let category, category != self.category { return false }
        if let severity, severity != self.severity { return false }
        guard !search.isEmpty else { return true }
        return ([code, self.category.rawValue, self.severity.rawValue] + Array(values.values))
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }
}

struct LocalActivityRetention: Codable, Equatable, Sendable {
    var minuteDays: Int = 30
    var eventDays: Int = 90
    var healthDays: Int = 366
    var validated: Self {
        .init(minuteDays: minuteDays.clamped(to: 1...90), eventDays: eventDays.clamped(to: 1...365),
              healthDays: healthDays.clamped(to: 1...366))
    }
}
