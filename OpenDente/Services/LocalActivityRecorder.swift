import AppKit
import Combine
import Foundation

@MainActor
final class LocalActivityPreferences: ObservableObject {
    static let shared = LocalActivityPreferences()
    @Published var minuteRetentionDays: Int {
        didSet { defaults.set(minuteRetentionDays.clamped(to: 1...90), forKey: "activity.minuteRetentionDays") }
    }
    @Published var eventRetentionDays: Int {
        didSet { defaults.set(eventRetentionDays.clamped(to: 1...365), forKey: "activity.eventRetentionDays") }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let minutes = defaults.integer(forKey: "activity.minuteRetentionDays")
        let events = defaults.integer(forKey: "activity.eventRetentionDays")
        minuteRetentionDays = minutes > 0 ? minutes.clamped(to: 1...90) : 30
        eventRetentionDays = events > 0 ? events.clamped(to: 1...365) : 90
    }
    var retention: LocalActivityRetention {
        .init(minuteDays: minuteRetentionDays, eventDays: eventRetentionDays, healthDays: 366)
    }
}

/// One lifecycle owner subscribes to measured data and structured policy results.
/// Singleton construction is inert; start is called after the app's test-host guard.
@MainActor
final class LocalActivityRecorder: ObservableObject {
    static let shared = LocalActivityRecorder()
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var storageError: String?
    let store: LocalActivityStore
    private let battery: BatteryService
    private let charging: ChargingManager
    private let helper: HelperStatusMonitor
    private let preferences: LocalActivityPreferences
    private let now: () -> Date
    private var accumulator = MinuteHistoryAccumulator()
    private var cancellables = Set<AnyCancellable>()
    private var persistence: Task<Void, Never>?
    private var running = false
    private var lastBatteryStateKey: String?

    init(store: LocalActivityStore = .init(), battery: BatteryService = .shared,
         charging: ChargingManager = .shared, helper: HelperStatusMonitor = .shared,
         preferences: LocalActivityPreferences = .shared, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.battery = battery
        self.charging = charging
        self.helper = helper
        self.preferences = preferences
        self.now = now
    }

    func start() {
        guard !running else { return }
        running = true
        accumulator = MinuteHistoryAccumulator()
        let retention = preferences.retention
        enqueue { try await $0.setRetention(retention) }
        record(.init(at: now(), category: .application, code: "application.started"), deduplicateFor: 0)
        battery.$batteryState.sink { [weak self] in self?.observe($0) }.store(in: &cancellables)
        charging.$mode.removeDuplicates().sink { [weak self] mode in
            self?.record(.init(category: .charging, code: "charging.modeObserved", values: ["mode": mode.rawValue]))
        }.store(in: &cancellables)
        charging.policyEvents.sink { [weak self] in self?.recordPolicy($0) }.store(in: &cancellables)
        MonthlyFullChargeService.shared.events.sink { [weak self] in self?.recordMonthly($0) }.store(in: &cancellables)
        helper.events.sink { [weak self] in self?.record($0) }.store(in: &cancellables)
        preferences.$minuteRetentionDays.combineLatest(preferences.$eventRetentionDays).dropFirst()
            .sink { [weak self] minuteDays, eventDays in
                let retention = LocalActivityRetention(minuteDays: minuteDays, eventDays: eventDays, healthDays: 366)
                self?.enqueue { try await $0.setRetention(retention) }
            }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.flushMinute()
                    self?.accumulator = MinuteHistoryAccumulator()
                    self?.record(.init(category: .application, code: "application.sleep"))
                }
            }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.accumulator = MinuteHistoryAccumulator()
                    self?.record(.init(category: .application, code: "application.wake"))
                }
            }.store(in: &cancellables)
        helper.start()
    }

    func stop() {
        guard running else { return }
        running = false
        cancellables.removeAll()
        helper.stop()
        flushMinute()
        record(.init(at: now(), category: .application, code: "application.stopped"), deduplicateFor: 0)
    }

    /// Call before an orderly exit when there is time to drain pending small writes.
    func flush() async {
        flushMinute()
        await persistence?.value
    }

    func clearHistory() async throws {
        await persistence?.value
        try await store.clearHistory()
        accumulator = MinuteHistoryAccumulator()
        revision &+= 1
    }
    func clearEvents() async throws {
        await persistence?.value
        try await store.clearEvents()
        revision &+= 1
    }

    private func observe(_ state: BatteryState) {
        guard running else { return }
        let timestamp = now()
        if let minute = accumulator.add(.init(state: state, at: timestamp)) {
            enqueue { try await $0.append(minute) }
        }
        let key = "\(state.hasValidBatteryReading)-\(state.isPluggedIn)-\(state.isCharging)-\(state.notChargingReason ?? 0)-\(state.chargerInhibitReason ?? 0)"
        guard key != lastBatteryStateKey else { return }
        lastBatteryStateKey = key
        record(.init(at: timestamp, category: .charging,
            severity: state.hasValidBatteryReading ? .info : .warning, code: "charging.telemetryObserved",
            values: ["valid": String(state.hasValidBatteryReading), "pluggedIn": String(state.isPluggedIn),
                     "charging": String(state.isCharging), "systemLimitActive": String(state.systemChargeLimitActive),
                     "notChargingReason": state.notChargingReason.map { "0x" + String($0, radix: 16) } ?? "",
                     "inhibitReason": state.chargerInhibitReason.map { "0x" + String($0, radix: 16) } ?? ""]))
    }

    private func flushMinute() {
        if let minute = accumulator.flush() { enqueue { try await $0.append(minute) } }
    }

    func record(_ event: LocalActivityEvent, deduplicateFor seconds: TimeInterval = 30) {
        enqueue { _ = try await $0.append(event, deduplicateFor: seconds) }
    }

    private func enqueue(_ operation: @escaping @Sendable (LocalActivityStore) async throws -> Void) {
        let previous = persistence
        let store = store
        persistence = Task { [weak self] in
            await previous?.value
            do {
                try await operation(store)
                self?.storageError = nil
                self?.revision &+= 1
            } catch {
                self?.storageError = error.localizedDescription
            }
        }
    }

    private func recordPolicy(_ event: NativeChargingPolicyEvent) {
        let code: String
        let values: [String: String]
        let severity: ActivitySeverity
        switch event {
        case .limitRequested(let value):
            code = "native.limitRequested"; values = ["limit": String(value)]; severity = .info
        case .optimizedChargingRequested(let enabled):
            code = "native.optimizedRequested"; values = ["enabled": String(enabled)]; severity = .info
        case .limitChanged(let previous, let current, let external):
            code = "native.limitConfirmed"
            values = ["previous": previous.map(String.init) ?? "", "limit": String(current), "external": String(external)]
            severity = .info
        case .optimizedChargingChanged(let previous, let enabled, let external):
            code = "native.optimizedConfirmed"
            values = ["previous": previous.map(String.init) ?? "", "enabled": String(enabled), "external": String(external)]
            severity = .info
        case .operationFailed(let operation, let failureCode, let details):
            code = "native.operationFailed"
            values = details.merging(["operation": operation, "failureCode": failureCode], uniquingKeysWith: { _, new in new })
            severity = .error
        }
        record(.init(at: now(), category: .nativePolicy, severity: severity, code: code, values: values))
    }

    private func recordMonthly(_ event: MonthlyFullChargeEvent) {
        let code: String
        let values: [String: String]
        let severity: ActivitySeverity
        switch event {
        case .scheduled(let date):
            code = "monthly.scheduled"; values = ["date": date.ISO8601Format()]; severity = .info
        case .pending(let reason):
            code = "monthly.pending"; values = ["reason": reason]; severity = .info
        case .started(let date):
            code = "monthly.started"; values = ["date": date.ISO8601Format()]; severity = .info
        case .completed(let date):
            code = "monthly.completed"; values = ["date": date.ISO8601Format()]; severity = .info
        case .cancelled:
            code = "monthly.cancelled"; values = [:]; severity = .warning
        case .failed(let failureCode, let details):
            code = "monthly.failed"
            values = details.merging(["failureCode": failureCode], uniquingKeysWith: { _, new in new })
            severity = .error
        }
        record(.init(at: now(), category: .monthlyCharge, severity: severity, code: code, values: values))
    }
}
