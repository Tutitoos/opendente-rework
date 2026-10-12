import Foundation
import Combine

enum MonthlyFullChargeStatus: String, Codable, CaseIterable, Sendable {
    case disabled, scheduled, waitingForPower, charging, completed, cancelled, failed
}

enum MonthlyFullChargeEvent: Equatable, Sendable {
    case scheduled(Date)
    case pending(reason: String)
    case started(Date)
    case completed(Date)
    case cancelled
    case failed(code: String, values: [String: String])
}

enum MonthlyFullChargeError: LocalizedError {
    case unavailable
    case invalidNextDate
    case policyChangedExternally
    case restoreFailed(String)
    case interrupted

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Native temporary full charging is unavailable."
        case .invalidNextDate: return "Choose a valid next full-charge date."
        case .policyChangedExternally: return "Monthly charging was cancelled because the charging policy changed."
        case .restoreFailed(let detail): return "The previous charging policy could not be restored: \(detail)"
        case .interrupted: return "Monthly charging was interrupted; the previous policy has been restored."
        }
    }
}

/// Written before requesting a temporary override, so partial writes and a
/// process exit cannot erase the information required for restoration.
struct MonthlyFullChargeCycle: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let previousPolicy: NativeChargingPolicySnapshot
    var temporaryPolicy: NativeChargingPolicySnapshot?
    var reachedFullAt: Date?
    var restorationPending: Bool
}

@MainActor
final class MonthlyFullChargeService: ObservableObject {
    static let shared = MonthlyFullChargeService(
        settings: .shared, battery: .shared, control: PowerUINativeChargeLimitControl(),
        policyEvents: ChargingManager.shared.policyEvents.eraseToAnyPublisher(),
        policyReady: { !ChargingManager.shared.isReleasingSMCForNative },
        journal: FileMonthlyFullChargeJournal.applicationSupport
    )

    let events = PassthroughSubject<MonthlyFullChargeEvent, Never>()
    @Published private(set) var status: MonthlyFullChargeStatus = .disabled
    @Published private(set) var lastFullChargeDate: Date?
    @Published private(set) var nextChargeDate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorSource: Error?
    @Published private(set) var canStart = false

    var enabled: Bool { settings.monthlyFullChargeEnabled }
    var isCharging: Bool { settings.monthlyFullChargeCycle != nil || settings.monthlyChargeRecoveryUnknown }

    private let settings: AppSettings
    private let battery: BatteryService
    private let control: any MonthlyFullChargeControl
    private let now: () -> Date
    private let calendar: Calendar
    private let pollingInterval: TimeInterval?
    private let policyReady: () -> Bool
    private let journal: any MonthlyFullChargeJournal
    private var journalLoaded = false
    private var journalError: Error?
    private let policyEvents: AnyPublisher<NativeChargingPolicyEvent, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var timer: AnyCancellable?
    private var running = false
    private var processing = false
    private var sawFullBattery: Bool

    init(settings: AppSettings, battery: BatteryService, control: any MonthlyFullChargeControl,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         policyEvents: AnyPublisher<NativeChargingPolicyEvent, Never>? = nil,
         pollingInterval: TimeInterval? = 60, policyReady: @escaping () -> Bool = { true },
         journal: (any MonthlyFullChargeJournal)? = nil) {
        self.settings = settings
        self.battery = battery
        self.control = control
        self.now = now
        self.calendar = calendar
        self.pollingInterval = pollingInterval
        self.policyReady = policyReady
        self.journal = journal ?? SettingsMonthlyFullChargeJournal(settings: settings)
        self.policyEvents = policyEvents
        lastFullChargeDate = settings.monthlyLastFullChargeDate
        nextChargeDate = settings.monthlyFullChargeNextDate
        sawFullBattery = settings.monthlyPreviouslyObservedFull
        status = settings.monthlyFullChargeEnabled ? .scheduled : .disabled
    }

    /// Call before ChargingManager.start(): interrupted native overrides are
    /// restored before a temporary100 can become the UI's habitual policy.
    func start() {
        guard !running else { return }
        running = true
        _ = loadJournal()
        refreshAvailability()
        if journalError == nil, let cycle = settings.monthlyFullChargeCycle {
            finishCycle(outcome: cycle.reachedFullAt == nil ? .cancelled : .completed,
                        failure: cycle.reachedFullAt == nil ? MonthlyFullChargeError.interrupted : nil)
        }
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.evaluate(state) }
            .store(in: &cancellables)
        policyEvents?.sink { [weak self] event in
            switch event {
            case .limitRequested, .optimizedChargingRequested:
                // This synchronous subject fires before the explicit writer.
                // Restore our override first, then let that action win.
                if self?.isCharging == true { self?.cancel() }
            default: break
            }
        }.store(in: &cancellables)
        if let interval = pollingInterval, interval > 0 {
            timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.evaluate(self.battery.batteryState)
                }
        }
        evaluate(battery.batteryState)
    }

    /// An orderly app exit restores immediately. A failed restore remains
    /// persisted and is retried before native-policy adoption on next launch.
    func stop() {
        if isCharging { finishCycle(outcome: .cancelled, failure: nil) }
        timer?.cancel()
        timer = nil
        cancellables.removeAll()
        running = false
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.monthlyFullChargeEnabled else { return }
        settings.monthlyFullChargeEnabled = enabled
        guard loadJournal() else { return }
        setError(nil)
        if !enabled {
            if isCharging { finishCycle(outcome: .disabled, failure: nil) }
            else { status = .disabled }
            return
        }
        refreshAvailability()
        // A new activation starts a future interval; an old observation does
        // not create an immediate catch-up charge. Existing active schedules
        // retain their due date across relaunches.
        let activation = now()
        schedule(from: max(activation, settings.monthlyLastFullChargeDate ?? activation))
        evaluate(battery.batteryState)
    }

    func setNextChargeDate(_ date: Date) {
        guard !isCharging, date.timeIntervalSinceReferenceDate.isFinite else {
            setError(MonthlyFullChargeError.invalidNextDate)
            return
        }
        settings.monthlyFullChargeNextDate = date
        nextChargeDate = date
        setError(nil)
        if enabled { status = .scheduled; events.send(.scheduled(date)) }
        evaluate(battery.batteryState)
    }

    func cancel() {
        if isCharging { finishCycle(outcome: .cancelled, failure: nil) }
        else {
            status = enabled ? .cancelled : .disabled
            events.send(.cancelled)
            // Cancellation never immediately starts the same overdue request.
            if enabled { schedule(from: now(), preservingStatus: true) }
        }
    }

    func retry() {
        guard loadJournal(force: true) else { return }
        setError(nil)
        refreshAvailability()
        if let cycle = settings.monthlyFullChargeCycle {
            let completed = cycle.reachedFullAt != nil
            finishCycle(outcome: completed ? .completed : (enabled ? .cancelled : .disabled), failure: nil)
            // Recovery is one operation. A recovered100% observation must not
            // open another cycle using a stale pre-completion battery sample.
            return
        }
        if enabled, !isCharging {
            if let nextChargeDate, nextChargeDate > now(), lastFullChargeDate != nil {
                status = .completed
                return
            }
            settings.monthlyFullChargeNextDate = now()
            nextChargeDate = settings.monthlyFullChargeNextDate
            status = .scheduled
            evaluate(battery.batteryState)
        }
    }

    /// Deterministic entry point for battery samples, sleep/wake and clock tests.
    func evaluate(_ state: BatteryState) {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        guard loadJournal() else { return }
        guard state.hasValidBatteryReading else { return }
        let observedFull = state.percentage >= 100
        let fullCountsForDuePeriod = enabled && nextChargeDate.map { $0 <= now() } == true
        if observedFull, !sawFullBattery || fullCountsForDuePeriod {
            let date = now()
            settings.monthlyLastFullChargeDate = date
            lastFullChargeDate = date
            if enabled { schedule(from: date, preservingStatus: isCharging) }
        }
        sawFullBattery = observedFull
        settings.monthlyPreviouslyObservedFull = observedFull

        if var cycle = settings.monthlyFullChargeCycle {
            if cycle.restorationPending {
                guard status != .failed else { return }
                finishCycle(outcome: cycle.reachedFullAt != nil ? .completed : .cancelled, failure: nil)
                return
            }
            if observedFull {
                cycle.reachedFullAt = now()
                do { try persistCycle(cycle) }
                catch { finishCycle(outcome: .failed, failure: error); return }
                finishCycle(outcome: .completed, failure: nil)
                return
            }
            do {
                let actual = try control.readFullChargePolicy()
                if let temporary = cycle.temporaryPolicy,
                   !actual.hasSamePolicy(as: temporary), !actual.hasSamePolicy(as: cycle.previousPolicy) {
                    // An external policy wins; do not reapply our saved limit.
                    finishCycle(outcome: .cancelled, failure: MonthlyFullChargeError.policyChangedExternally)
                    return
                }
                // OBC may start retaining the battery later while its enabled
                // policy stays1. Do not add another override or report100:
                // restore this cycle, record failure and require explicit retry.
                guard try control.canContinueTemporaryFullCharge() else {
                    finishCycle(outcome: .failed, failure: MonthlyFullChargeError.interrupted)
                    return
                }
            } catch {
                finishCycle(outcome: .failed, failure: error)
                return
            }
            if !state.isPluggedIn || now().timeIntervalSince(cycle.startedAt) >= 24 * 60 * 60 {
                finishCycle(outcome: .cancelled, failure: MonthlyFullChargeError.interrupted)
                return
            }
            status = .charging
            return
        }
        guard enabled else { status = .disabled; return }
        if observedFull { status = .completed; return }
        if nextChargeDate == nil { schedule(from: settings.monthlyLastFullChargeDate ?? now()) }
        guard let due = nextChargeDate, due <= now() else { return }
        guard status != .failed else { return }
        guard state.isPluggedIn else {
            if status != .waitingForPower { events.send(.pending(reason: "power")) }
            status = .waitingForPower
            return
        }
        guard policyReady() else {
            status = .scheduled
            events.send(.pending(reason: "smcRecovery"))
            return
        }
        refreshAvailability()
        guard canStart else {
            fail(MonthlyFullChargeError.unavailable)
            return
        }
        beginCycle()
    }

    private func refreshAvailability() {
        guard journalError == nil else { canStart = false; return }
        do { canStart = try control.temporaryFullChargeAvailable() }
        catch { canStart = false; setError(error) }
    }

    private func schedule(from date: Date, preservingStatus: Bool = false) {
        // Calendar months handle short months and DST; skip missed periods,
        // because the next date derives from the new observed full charge.
        let next = calendar.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(31 * 86400)
        settings.monthlyFullChargeNextDate = next
        nextChargeDate = next
        if !preservingStatus { status = .scheduled }
        events.send(.scheduled(next))
    }

    private func beginCycle() {
        do {
            let previous = try control.readFullChargePolicy()
            // Do not take ownership of a temporary override started in macOS
            // or another app. Observe its100% result if it happens naturally.
            guard !previous.chargeLimit.isTemporaryOverride,
                  previous.optimizedChargingState != 2, previous.optimizedChargingState != 3 else {
                status = .scheduled
                events.send(.pending(reason: "systemOverride"))
                return
            }
            var cycle = MonthlyFullChargeCycle(id: UUID(), startedAt: now(), previousPolicy: previous,
                                               temporaryPolicy: nil, reachedFullAt: nil, restorationPending: false)
            try persistCycle(cycle)
            cycle.temporaryPolicy = try control.beginTemporaryFullCharge(expectedPolicy: previous)
            try persistCycle(cycle)
            status = .charging
            setError(nil)
            events.send(.started(cycle.startedAt))
        } catch {
            if settings.monthlyFullChargeCycle != nil { finishCycle(outcome: .failed, failure: error) }
            else { fail(error) }
        }
    }

    private func finishCycle(outcome: MonthlyFullChargeStatus, failure: Error?) {
        guard var cycle = settings.monthlyFullChargeCycle else { return }
        do {
            cycle.restorationPending = true
            try persistCycle(cycle)
            let actual = try control.readFullChargePolicy()
            // Merge per feature: changing a limit externally must not keep our
            // OBC override, and changing OBC externally must not keep our limit.
            let temporary = cycle.temporaryPolicy
            let currentLimitIsOurs = actual.chargeLimit == cycle.previousPolicy.chargeLimit ||
                actual.chargeLimit == temporary?.chargeLimit ||
                (temporary == nil && cycle.previousPolicy.chargeLimit.enabled && actual.chargeLimit.isTemporaryOverride)
            let currentOptimizedIsOurs = actual.optimizedChargingState == cycle.previousPolicy.optimizedChargingState ||
                actual.optimizedChargingState == temporary?.optimizedChargingState ||
                (temporary == nil && cycle.previousPolicy.optimizedChargingState == 1 && actual.optimizedChargingState == 2)
            let intended = NativeChargingPolicySnapshot(
                chargeLimit: currentLimitIsOurs ? cycle.previousPolicy.chargeLimit : actual.chargeLimit,
                optimizedChargingEnabled: currentOptimizedIsOurs ? cycle.previousPolicy.optimizedChargingEnabled : actual.optimizedChargingEnabled,
                optimizedChargingState: currentOptimizedIsOurs ? cycle.previousPolicy.optimizedChargingState : actual.optimizedChargingState
            )
            if !actual.hasSamePolicy(as: intended) {
                _ = try control.restoreAfterTemporaryFullCharge(intended)
            }
            // Verify independently, even if an injected/native writer returns
            // the requested snapshot as its reply.
            let restored = try control.readFullChargePolicy()
            guard restored.hasSamePolicy(as: intended) else {
                throw MonthlyFullChargeError.restoreFailed("macOS readback differs")
            }
            try persistCycle(nil)
            status = outcome
            setError(failure)
            if let full = cycle.reachedFullAt {
                // Only real100% telemetry can move the successful-charge date.
                settings.monthlyLastFullChargeDate = full
                lastFullChargeDate = full
                if enabled { schedule(from: full, preservingStatus: true) }
            } else if enabled, outcome == .cancelled {
                schedule(from: now(), preservingStatus: true)
            }
            switch outcome {
            case .completed: events.send(.completed(cycle.reachedFullAt ?? now()))
            case .failed: sendFailure(failure ?? MonthlyFullChargeError.interrupted)
            default: events.send(.cancelled)
            }
        } catch {
            fail(MonthlyFullChargeError.restoreFailed(error.localizedDescription))
            // Keep the recovery record. Never declare restored or completed.
        }
    }

    private func fail(_ error: Error) {
        status = .failed
        setError(error)
        sendFailure(error)
    }

    private func setError(_ error: Error?) {
        errorSource = error
        errorMessage = error?.localizedDescription
    }

    private func sendFailure(_ error: Error) {
        let failure = ChargingPolicyFailure(error: error)
        events.send(.failed(code: failure.code, values: failure.values))
    }

    private func loadJournal(force: Bool = false) -> Bool {
        if journalLoaded, !force { return journalError == nil }
        journalLoaded = true
        do {
            var cycle = try journal.read()
            if journal is FileMonthlyFullChargeJournal, !settings.monthlyCycleJournalMigrated,
               cycle == nil, settings.defaults.object(forKey: "monthlyFullChargeCycle") != nil {
                // One-way migration must also be durable before restoration.
                cycle = try SettingsMonthlyFullChargeJournal(settings: settings).read()
                try journal.write(cycle)
            }
            settings.monthlyFullChargeCycle = cycle
            settings.monthlyCycleJournalMigrated = true
            settings.monthlyChargeRecoveryUnknown = false
            journalError = nil
            return true
        } catch {
            journalError = error
            settings.monthlyChargeRecoveryUnknown = true
            canStart = false
            fail(error)
            return false
        }
    }

    private func persistCycle(_ cycle: MonthlyFullChargeCycle?) throws {
        do {
            try journal.write(cycle)
            // The synchronous disk operation has completed; only now publish
            // the preference mirror used by the UI/native policy manager.
            settings.monthlyFullChargeCycle = cycle
            settings.monthlyChargeRecoveryUnknown = false
            journalError = nil
        } catch {
            journalError = error
            settings.monthlyChargeRecoveryUnknown = true
            throw error
        }
    }
}
