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

    init(state: BatteryState, at timestamp: Date) {
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

struct BatteryHistoryMinute: Codable, Identifiable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let timestamp: Date
    let firstObservedAt: Date
    let lastObservedAt: Date
    let readingCount: Int
    let validChargeReadingCount: Int
    let averages: [String: Double]
    let valueCounts: [String: Int]
    let metricLastObservedAt: [String: Date]
    let sources: [String: [String]]
    let healthQualities: [String]
    var id: String { "\(sessionID.uuidString)-\(firstObservedAt.timeIntervalSince1970)-\(lastObservedAt.timeIntervalSince1970)" }
    func value(_ metric: HistoryMetric) -> Double? { averages[metric.rawValue] }
}

/// One minute is written once. A long pause creates a new minute, never synthetic samples.
struct MinuteHistoryAccumulator {
    private var current: [BatteryHistoryReading] = []
    private let sessionID: UUID
    init(sessionID: UUID = UUID()) { self.sessionID = sessionID }

    mutating func add(_ reading: BatteryHistoryReading) -> BatteryHistoryMinute? {
        let previous = current.first.map { Self.minute($0.timestamp) }
        let flushed = previous != nil && previous != Self.minute(reading.timestamp) ? flush() : nil
        current.append(reading)
        return flushed
    }

    mutating func flush() -> BatteryHistoryMinute? {
        guard let first = current.first, let last = current.last else { return nil }
        var sums: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var sources: [String: Set<String>] = [:]
        var metricTimes: [String: Date] = [:]
        for reading in current {
            for (metric, value) in reading.values {
                sums[metric.rawValue, default: 0] += value
                counts[metric.rawValue, default: 0] += 1
                metricTimes[metric.rawValue] = reading.timestamp
                if let source = reading.sources[metric.rawValue] { sources[metric.rawValue, default: []].insert(source) }
            }
        }
        let result = BatteryHistoryMinute(schemaVersion: 1, sessionID: sessionID,
            timestamp: Self.minute(first.timestamp), firstObservedAt: first.timestamp,
            lastObservedAt: last.timestamp, readingCount: current.count,
            validChargeReadingCount: current.filter(\.chargeValid).count,
            averages: sums.mapValues { $0 }.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value / Double(counts[entry.key, default: 1])
            }, valueCounts: counts, metricLastObservedAt: metricTimes, sources: sources.mapValues { $0.sorted() },
            healthQualities: Array(Set(current.map(\.healthQuality))).sorted())
        current.removeAll(keepingCapacity: true)
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
        var segments: [[HistoryPlotPoint]] = []
        var previous: BatteryHistoryMinute?
        var broken = true
        for row in rows.sorted(by: { $0.firstObservedAt < $1.firstObservedAt }) {
            guard let value = row.value(metric), value.isFinite else { broken = true; continue }
            let gap = previous.map { row.firstObservedAt.timeIntervalSince($0.lastObservedAt) > 15
                || row.firstObservedAt < $0.lastObservedAt || row.sessionID != $0.sessionID } ?? true
            if broken || gap { segments.append([]) }
            let segment = segments.count - 1
            segments[segment].append(.init(timestamp: row.timestamp, value: value, segment: segment))
            previous = row
            broken = false
        }
        let total = segments.reduce(0) { $0 + $1.count }
        let step = max(1, Int(ceil(Double(total) / Double(max(1, maximumPoints)))))
        return segments.flatMap { segment in
            segment.enumerated().compactMap { index, point in
                index == 0 || index == segment.count - 1 || index.isMultiple(of: step) ? point : nil
            }
        }
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
