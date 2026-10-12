import Foundation
import Combine
import Testing
@testable import OpenDente

@Suite("Monthly full charging")
@MainActor
struct MonthlyFullChargeServiceTests {
    @Test func disabledByDefaultAndActivationSchedulesCalendarMonth() {
        let f = MonthlyFixture(date: monthlyDate(2026, 1, 31))
        defer { f.cleanUp() }
        #expect(!f.service.enabled)
        #expect(f.service.status == .disabled)
        f.service.setEnabled(true)
        #expect(f.service.nextChargeDate == monthlyDate(2026, 2, 28))
        #expect(f.control.begins == 0)
    }

    @Test func overdueRequestWaitsForPowerAndRunsOnce() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.service.setEnabled(true)
        f.battery.batteryState = makeBatteryState(percentage: 80, isPluggedIn: false)
        f.service.setNextChargeDate(f.clock.date.addingTimeInterval(-90 * 86400))
        #expect(f.service.status == .waitingForPower)
        #expect(f.control.begins == 0)
        let plugged = makeBatteryState(percentage: 80, isCharging: true)
        f.service.evaluate(plugged)
        f.service.evaluate(plugged)
        #expect(f.service.status == .charging)
        #expect(f.control.begins == 1)
        #expect(f.settings.monthlyFullChargeCycle?.previousPolicy == monthlyPolicy(80))
        #expect(f.control.policy.chargeLimit.nativeFeatureState == 3)
    }

    @Test func onlyObserved100CompletesAndRestores() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.service.evaluate(makeBatteryState(percentage: 99, isCharging: true))
        #expect(f.service.status == .charging)
        #expect(f.service.lastFullChargeDate == nil)
        f.clock.date = f.clock.date.addingTimeInterval(3600)
        f.service.evaluate(makeBatteryState(percentage: 100))
        #expect(f.service.status == .completed)
        #expect(f.service.lastFullChargeDate == f.clock.date)
        #expect(f.service.nextChargeDate == monthlyDate(2026, 11, 12, hour: 13))
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.settings.monthlyFullChargeCycle == nil)
        #expect(f.control.restores.count == 1)
    }

    @Test func alreadyObserved100CountsWithoutAnOverride() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.battery.batteryState = makeBatteryState(percentage: 100)
        f.service.setEnabled(true)
        #expect(f.control.begins == 0)
        #expect(f.service.lastFullChargeDate == f.clock.date)
        let first = f.service.nextChargeDate
        f.clock.date = f.clock.date.addingTimeInterval(600)
        f.service.evaluate(f.battery.batteryState)
        #expect(f.service.nextChargeDate == first)
    }

    @Test func newActivationNeverChargesImmediatelyForAnOldFullObservation() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.settings.monthlyLastFullChargeDate = monthlyDate(2026, 6, 12)
        f.service.setEnabled(true)
        #expect(f.service.nextChargeDate == monthlyDate(2026, 11, 12))
        #expect(f.control.begins == 0)
        f.service.setEnabled(false)
        f.clock.date = monthlyDate(2026, 12, 12)
        f.service.setEnabled(true)
        #expect(f.service.nextChargeDate == monthlyDate(2027, 1, 12))
        #expect(f.control.begins == 0)
    }

    @Test func overduePersistedFullObservationCountsCurrentMonthOnRelaunch() {
        let f = MonthlyFixture(date: monthlyDate(2026, 10, 15))
        defer { f.cleanUp() }
        f.settings.monthlyFullChargeEnabled = true
        f.settings.monthlyLastFullChargeDate = monthlyDate(2026, 9, 1)
        f.settings.monthlyFullChargeNextDate = monthlyDate(2026, 10, 1)
        f.settings.monthlyPreviouslyObservedFull = true
        f.battery.batteryState = makeBatteryState(percentage: 100)
        let next = MonthlyFullChargeService(settings: f.settings, battery: f.battery, control: f.control,
                                           now: { f.clock.date }, calendar: f.calendar, pollingInterval: nil)
        next.start()
        defer { next.stop() }
        #expect(next.status == .completed)
        #expect(next.lastFullChargeDate == f.clock.date)
        #expect(next.nextChargeDate == monthlyDate(2026, 11, 15))
        #expect(f.control.begins == 0)
        f.clock.date = f.clock.date.addingTimeInterval(600)
        next.evaluate(makeBatteryState(percentage: 100))
        next.evaluate(makeBatteryState(percentage: 99))
        #expect(next.nextChargeDate == monthlyDate(2026, 11, 15))
        #expect(f.control.begins == 0)
    }

    @Test func alreadyActiveOverdueScheduleRelaunchesWithoutMissedMonthCatchup() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.settings.monthlyFullChargeEnabled = true
        f.settings.monthlyFullChargeNextDate = monthlyDate(2026, 7, 12)
        let next = MonthlyFullChargeService(settings: f.settings, battery: f.battery, control: f.control,
                                           now: { f.clock.date }, calendar: f.calendar, pollingInterval: nil)
        next.start()
        defer { next.stop() }
        next.evaluate(makeBatteryState(percentage: 80))
        #expect(f.control.begins == 1)
        #expect(next.status == .charging)
        next.evaluate(makeBatteryState(percentage: 100))
        #expect(next.nextChargeDate == monthlyDate(2026, 11, 12))
        #expect(f.control.begins == 1)
    }

    @Test func cancelRestoresAndDoesNotImmediatelyRestartOverdueRequest() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.service.cancel()
        #expect(f.service.status == .cancelled)
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.service.nextChargeDate == monthlyDate(2026, 11, 12))
        f.service.evaluate(makeBatteryState(percentage: 80))
        #expect(f.control.begins == 1)
    }

    @Test func disablingAnActiveCycleRestoresBeforeReportingDisabled() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.service.setEnabled(false)
        #expect(!f.service.enabled)
        #expect(f.service.status == .disabled)
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.settings.monthlyFullChargeCycle == nil)
    }

    @Test func external100IsDifferentFromOwnTemporary100() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.control.policy = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 0),
                                                        optimizedChargingEnabled: true, optimizedChargingState: 2)
        f.service.evaluate(makeBatteryState(percentage: 85))
        #expect(f.service.status == .cancelled)
        #expect(f.control.policy.chargeLimit.nativeFeatureState == 0)
        #expect(f.control.policy.chargeLimit.effectiveLimit == 100)
        #expect(f.control.policy.optimizedChargingState == 1)
    }

    @Test func externalOptimizedOffWinsWhileOurLimitIsRestored() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.control.policy = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 3),
                                                        optimizedChargingEnabled: false, optimizedChargingState: 0)
        f.service.evaluate(makeBatteryState(percentage: 85))
        #expect(f.service.status == .cancelled)
        #expect(f.control.policy.chargeLimit.effectiveLimit == 80)
        #expect(f.control.policy.optimizedChargingEnabled == false)
    }

    @Test func externallyChangedLimitIsPreservedAndOwnOBCOverrideEnds() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.control.policy = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(90),
                                                        optimizedChargingEnabled: true, optimizedChargingState: 2)
        f.service.evaluate(makeBatteryState(percentage: 85))
        #expect(f.control.policy == monthlyPolicy(90))
        #expect(f.service.status == .cancelled)
    }

    @Test func partialStartFailureUsesPersistedPreviousPolicyForRecovery() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.control.beginFailure = true
        f.begin()
        #expect(f.service.status == .failed)
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.settings.monthlyFullChargeCycle == nil)
        #expect(f.service.lastFullChargeDate == nil)
    }

    @Test func policyChangedAfterDurableJournalDoesNotBecomeOurOverride() {
        let journal = MonthlyJournalMock()
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        var changed = false
        journal.onWrite = { cycle in
            guard cycle != nil, !changed else { return }
            changed = true
            f.control.policy = monthlyPolicy(85)
        }
        f.begin()
        #expect(f.control.begins == 0 && f.control.restores.isEmpty)
        #expect(f.control.policy == monthlyPolicy(85))
        #expect(f.service.status == .failed && f.service.lastFullChargeDate == nil)
        #expect(f.settings.monthlyFullChargeCycle == nil && journal.cycle == nil)
        f.service.evaluate(makeBatteryState(percentage: 80))
        #expect(f.control.begins == 0)
    }

    @Test(arguments: [1, 3])
    func partialIndependentOverridesRecoverFromDurablePolicy(mclState: Int) {
        let f = MonthlyFixture(journal: MonthlyJournalMock())
        defer { f.cleanUp() }
        f.control.beginFailure = true
        f.control.partialBeginPolicy = NativeChargingPolicySnapshot(
            chargeLimit: mclState == 1 ? monthlyLimit(80) : monthlyLimit(100, state: 3),
            optimizedChargingEnabled: true, optimizedChargingState: mclState == 1 ? 2 : 1
        )
        f.begin()
        #expect(f.service.status == .failed)
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.settings.monthlyFullChargeCycle == nil)
        #expect(f.service.lastFullChargeDate == nil && f.control.restores.count == 1)
    }

    @Test(arguments: [false, true])
    func lateRetentionOrReadErrorRestoresAndStaysFailedWithoutRetry(readError: Bool) {
        let f = MonthlyFixture(journal: MonthlyJournalMock())
        defer { f.cleanUp() }
        f.control.overrideOptimized = false
        f.begin()
        #expect(f.control.policy.optimizedChargingState == 1)
        var failures = 0
        let recording = f.service.events.sink { event in if case .failed = event { failures += 1 } }
        defer { recording.cancel() }
        f.control.canContinue = false
        if readError { f.control.continuationError = NSError(domain: "PowerUISmartChargingErrorDomain", code: 2) }
        f.service.evaluate(makeBatteryState(percentage: 99, isCharging: true))
        #expect(f.service.status == .failed && failures == 1)
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.settings.monthlyFullChargeCycle == nil && f.service.lastFullChargeDate == nil)
        #expect(f.control.restores.count == 1)
        for _ in 0..<3 { f.service.evaluate(makeBatteryState(percentage: 80)) }
        #expect(f.control.begins == 1 && failures == 1 && f.service.status == .failed)
    }

    @Test func failedRestoreIsPersistedAndNeverClaimsCompletion() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.control.restoreFailure = true
        f.service.evaluate(makeBatteryState(percentage: 100))
        #expect(f.service.status == .failed)
        #expect(f.settings.monthlyFullChargeCycle?.restorationPending == true)
        let writes = f.control.restores.count
        f.service.evaluate(makeBatteryState(percentage: 100))
        #expect(f.control.restores.count == writes)
        f.control.restoreFailure = false
        f.service.retry()
        #expect(f.settings.monthlyFullChargeCycle == nil)
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.service.status == .completed)
        #expect(f.control.begins == 1)
    }

    @Test func successfulRestoreReplyWithoutMatchingReadbackKeepsRecoveryRecord() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.control.honorsRestores = false
        f.service.cancel()
        #expect(f.service.status == .failed)
        #expect(f.service.isCharging)
        #expect(f.settings.monthlyFullChargeCycle?.restorationPending == true)
        #expect(f.service.errorSource as? MonthlyFullChargeError != nil)
        #expect(f.control.policy.chargeLimit.isTemporaryOverride)
    }

    @Test func restartRecoversAnObservedFullChargeWithoutStartingAnotherCycle() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.control.restoreFailure = true
        f.service.evaluate(makeBatteryState(percentage: 100))
        f.control.restoreFailure = false
        let next = MonthlyFullChargeService(settings: f.settings, battery: f.battery, control: f.control,
                                           now: { f.clock.date }, calendar: f.calendar, pollingInterval: nil)
        next.start()
        defer { next.stop() }
        #expect(next.status == .completed)
        #expect(next.lastFullChargeDate == f.clock.date)
        #expect(next.nextChargeDate == monthlyDate(2026, 11, 12))
        #expect(f.control.begins == 1)
        #expect(f.settings.monthlyFullChargeCycle == nil)
    }

    @Test func incompleteJournalDoesNotUndoExternalPersistent100OrDisabledOBC() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        var cycle = f.settings.monthlyFullChargeCycle!
        cycle.temporaryPolicy = nil
        f.settings.monthlyFullChargeCycle = cycle
        f.control.policy = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 0),
                                                        optimizedChargingEnabled: false, optimizedChargingState: 0)
        let external = f.control.policy
        let next = MonthlyFullChargeService(settings: f.settings, battery: f.battery, control: f.control,
                                           now: { f.clock.date }, calendar: f.calendar, pollingInterval: nil)
        next.start()
        defer { next.stop() }
        #expect(f.control.policy == external)
        #expect(next.status == .cancelled)
        #expect(f.settings.monthlyFullChargeCycle == nil)
    }

    @Test func failuresEmitStableCodesAndParametersRatherThanPresentationText() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        var failures: [(String, [String: String])] = []
        let observer = f.service.events.sink { event in
            if case .failed(let code, let values) = event { failures.append((code, values)) }
        }
        defer { observer.cancel() }
        f.begin()
        f.control.restoreFailure = true
        f.service.cancel()
        #expect(failures.first?.0 == "monthlyRestoreFailed")
        #expect(failures.first?.1["detail"] != nil)
        #expect(f.service.errorSource as? MonthlyFullChargeError != nil)
    }

    @Test func relaunchRestoresPersistedOverrideBeforeEvaluatingAnyNewCycle() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        let next = MonthlyFullChargeService(settings: f.settings, battery: f.battery,
                                           control: f.control, now: { f.clock.date }, calendar: f.calendar,
                                           pollingInterval: nil)
        next.start()
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.control.begins == 1)
        #expect(f.settings.monthlyFullChargeCycle == nil)
        #expect(next.status == .cancelled)
        next.stop()
    }

    @Test func unplugOrTimeoutRestoresWithoutClaiming100() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.begin()
        f.clock.date = f.clock.date.addingTimeInterval(86401)
        f.service.evaluate(makeBatteryState(percentage: 90))
        #expect(f.service.status == .cancelled)
        #expect(f.service.lastFullChargeDate == nil)
        #expect(f.control.policy == monthlyPolicy(80))
    }

    @Test func unsupportedOrUnknownBatteryCannotWrite() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.control.available = false
        f.service.setEnabled(true)
        f.battery.batteryState = .unknown
        f.service.setNextChargeDate(f.clock.date)
        #expect(f.control.begins == 0)
        f.service.evaluate(makeBatteryState(percentage: 80))
        #expect(f.service.status == .failed)
        #expect(f.control.begins == 0)
    }

    @Test func explicitPolicyActionRestoresSynchronouslyBeforeTheWriter() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.service.start()
        f.begin()
        f.policyEvents.send(.limitRequested(90))
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(!f.service.isCharging)
        #expect(f.service.status == .cancelled)
        f.service.stop()
    }

    @Test func existingSystemOverrideIsObservedWithoutTakingOwnership() {
        let f = MonthlyFixture()
        defer { f.cleanUp() }
        f.control.policy = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 3),
                                                        optimizedChargingEnabled: true, optimizedChargingState: 2)
        f.begin()
        #expect(f.control.begins == 0)
        #expect(!f.service.isCharging)
        #expect(f.control.restores.isEmpty)
    }

    @Test func journalWriteMustSucceedBeforeAnyNativeOverride() {
        let journal = MonthlyJournalMock()
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        journal.writeFailure = MonthlyChargeJournalError.system(operation: "syncFile", code: 5)
        f.begin()
        #expect(f.control.begins == 0 && f.control.restores.isEmpty)
        #expect(f.service.status == .failed && f.service.isCharging)
        #expect(f.settings.monthlyChargeRecoveryUnknown)
        #expect(f.settings.monthlyFullChargeCycle == nil)
        f.service.evaluate(makeBatteryState(percentage: 80))
        #expect(f.control.begins == 0)
    }

    @Test func failedJournalReadDoesNotMeanNoCycleAndNeverWritesHardware() {
        let journal = MonthlyJournalMock()
        journal.readFailure = MonthlyChargeJournalError.system(operation: "read", code: 5)
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        f.settings.monthlyFullChargeEnabled = true
        f.settings.monthlyFullChargeNextDate = f.clock.date
        f.settings.monthlyFullChargeCycle = monthlyCycle(startedAt: f.clock.date)
        f.service.start()
        #expect(f.service.status == .failed && !f.service.canStart)
        #expect(f.service.isCharging && f.settings.monthlyChargeRecoveryUnknown)
        #expect(f.settings.monthlyFullChargeCycle != nil)
        #expect(f.control.begins == 0 && f.control.restores.isEmpty)
    }

    @Test func corruptedDiskJournalBlocksOverridesAndKeepsThePreferenceMirror() throws {
        let directory = monthlyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FileMonthlyFullChargeJournal(directory: directory)
        try journal.write(monthlyCycle(startedAt: monthlyDate(2026, 10, 12)))
        try Data("not a recovery record".utf8).write(to: directory.appendingPathComponent("monthly-charge-cycle.json"))
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        f.settings.monthlyFullChargeEnabled = true
        f.settings.monthlyFullChargeCycle = monthlyCycle(startedAt: f.clock.date)
        f.service.start()
        #expect(f.service.status == .failed && !f.service.canStart)
        #expect(f.settings.monthlyChargeRecoveryUnknown)
        #expect(f.settings.monthlyFullChargeCycle != nil)
        #expect(f.control.begins == 0 && f.control.restores.isEmpty)
        #expect(f.service.errorSource as? MonthlyChargeJournalError != nil)
    }

    @Test(arguments: ["prepared", "partial", "active", "restoring", "observedFull", "restoredFull"])
    func diskJournalRecoversFromEveryInterruptionPhase(phase: String) throws {
        let directory = monthlyTemporaryDirectory().appendingPathComponent("OpenDente/Charging", isDirectory: true)
        let temporaryRoot = directory.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let journal = FileMonthlyFullChargeJournal(directory: directory)
        let date = monthlyDate(2026, 10, 12)
        let temporary = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 3),
                                                     optimizedChargingEnabled: true, optimizedChargingState: 2)
        var cycle = monthlyCycle(startedAt: date.addingTimeInterval(-300))
        if phase != "prepared" && phase != "partial" { cycle.temporaryPolicy = temporary }
        if ["restoring", "observedFull", "restoredFull"].contains(phase) { cycle.restorationPending = true }
        if ["observedFull", "restoredFull"].contains(phase) { cycle.reachedFullAt = date }
        try journal.write(cycle)
        #expect(try journal.read() == cycle)
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        f.settings.monthlyFullChargeEnabled = true
        f.settings.monthlyFullChargeNextDate = date.addingTimeInterval(-60)
        if phase == "partial" {
            f.control.policy = NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 3),
                                                            optimizedChargingEnabled: true, optimizedChargingState: 1)
        } else if phase != "prepared" && phase != "restoredFull" { f.control.policy = temporary }
        f.service.start()
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.control.begins == 0)
        #expect(f.control.restores.count == (["prepared", "restoredFull"].contains(phase) ? 0 : 1))
        #expect(f.settings.monthlyFullChargeCycle == nil && !f.settings.monthlyChargeRecoveryUnknown)
        #expect(try journal.read() == nil)
        #expect(f.service.status == (["observedFull", "restoredFull"].contains(phase) ? .completed : .cancelled))
        #expect(f.service.nextChargeDate == monthlyDate(2026, 11, 12))
    }

    @Test func diskJournalMigratesAValidOldPreferenceRecordBeforeRestoring() throws {
        let directory = monthlyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FileMonthlyFullChargeJournal(directory: directory)
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        f.settings.monthlyFullChargeCycle = monthlyCycle(startedAt: f.clock.date)
        f.service.start()
        #expect(f.settings.monthlyCycleJournalMigrated)
        #expect(f.settings.monthlyFullChargeCycle == nil)
        #expect(try journal.read() == nil)
        #expect(f.control.begins == 0 && f.control.restores.isEmpty)
    }

    @Test func diskJournalRejectsInvalidPolicyInsteadOfAcceptingARecord() throws {
        let directory = monthlyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FileMonthlyFullChargeJournal(directory: directory)
        let invalid = MonthlyFullChargeCycle(id: UUID(), startedAt: monthlyDate(2026, 10, 12),
                                             previousPolicy: NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 3),
                                                                                         optimizedChargingEnabled: true),
                                             temporaryPolicy: nil, reachedFullAt: nil, restorationPending: false)
        #expect(throws: MonthlyChargeJournalError.self) { try journal.write(invalid) }
        #expect(try journal.read() == nil)
    }

    @Test func failedClearAfterRestoringIsRecoveredWithoutRepeatingHardwareWrites() {
        let journal = MonthlyJournalMock()
        let f = MonthlyFixture(journal: journal)
        defer { f.cleanUp() }
        f.begin()
        journal.failRemovals = true
        f.service.evaluate(makeBatteryState(percentage: 100))
        #expect(f.control.policy == monthlyPolicy(80))
        #expect(f.service.status == .failed && f.settings.monthlyChargeRecoveryUnknown)
        #expect(journal.cycle?.reachedFullAt == f.clock.date)
        #expect(f.control.restores.count == 1)
        journal.failRemovals = false
        f.service.retry()
        #expect(f.service.status == .completed)
        #expect(f.settings.monthlyFullChargeCycle == nil && journal.cycle == nil)
        #expect(f.control.restores.count == 1 && f.control.begins == 1)
    }
}

private func monthlyDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func monthlyLimit(_ limit: Int, state: Int = 1) -> NativeChargeLimitSnapshot {
    NativeChargeLimitSnapshot(availableLimits: [80, 85, 90, 95, 100], limit: limit,
                              enabled: state == 1, nativeFeatureState: state)
}

private func monthlyPolicy(_ limit: Int, optimized: Bool = true) -> NativeChargingPolicySnapshot {
    NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(limit), optimizedChargingEnabled: optimized)
}

private func monthlyCycle(startedAt: Date) -> MonthlyFullChargeCycle {
    MonthlyFullChargeCycle(id: UUID(), startedAt: startedAt, previousPolicy: monthlyPolicy(80),
                           temporaryPolicy: nil, reachedFullAt: nil, restorationPending: false)
}

private func monthlyTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("opendente-monthly-tests-" + UUID().uuidString, isDirectory: true)
}

@MainActor
private final class MonthlyJournalMock: MonthlyFullChargeJournal {
    var cycle: MonthlyFullChargeCycle?
    var readFailure: Error?
    var writeFailure: Error?
    var failRemovals = false
    var onWrite: ((MonthlyFullChargeCycle?) -> Void)?
    func read() throws -> MonthlyFullChargeCycle? {
        if let readFailure { throw readFailure }
        return cycle
    }
    func write(_ cycle: MonthlyFullChargeCycle?) throws {
        if let writeFailure { throw writeFailure }
        if cycle == nil, failRemovals { throw MonthlyChargeJournalError.system(operation: "remove", code: 5) }
        self.cycle = cycle
        onWrite?(cycle)
    }
}

@MainActor
private final class MonthlyClock { var date: Date; init(_ date: Date) { self.date = date } }

@MainActor
private final class MonthlyFixture {
    let suite = "com.opendente.tests.monthly." + UUID().uuidString
    let settings: AppSettings
    let battery: BatteryService
    let control = MonthlyNativeMock()
    let clock: MonthlyClock
    let calendar: Calendar
    let policyEvents = PassthroughSubject<NativeChargingPolicyEvent, Never>()
    let service: MonthlyFullChargeService

    init(date: Date = monthlyDate(2026, 10, 12), journal: (any MonthlyFullChargeJournal)? = nil) {
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        battery = BatteryService(settings: settings)
        battery.batteryState = makeBatteryState(percentage: 80)
        clock = MonthlyClock(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        let clock = self.clock
        service = MonthlyFullChargeService(settings: settings, battery: battery, control: control,
                                           now: { clock.date }, calendar: calendar,
                                           policyEvents: policyEvents.eraseToAnyPublisher(), pollingInterval: nil, journal: journal)
    }
    func begin() { service.setEnabled(true); service.setNextChargeDate(clock.date) }
    func cleanUp() { service.stop(); settings.defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class MonthlyNativeMock: MonthlyFullChargeControl {
    var available = true
    var policy = monthlyPolicy(80)
    var beginFailure = false
    var restoreFailure = false
    var honorsRestores = true
    var overrideOptimized = true
    var partialBeginPolicy: NativeChargingPolicySnapshot?
    var canContinue = true
    var continuationError: Error?
    private(set) var begins = 0
    private(set) var restores: [NativeChargingPolicySnapshot] = []
    func temporaryFullChargeAvailable() throws -> Bool { available }
    func readFullChargePolicy() throws -> NativeChargingPolicySnapshot { policy }
    func canContinueTemporaryFullCharge() throws -> Bool {
        if let continuationError { throw continuationError }
        return canContinue
    }
    func beginTemporaryFullCharge() throws -> NativeChargingPolicySnapshot {
        begins += 1
        policy = partialBeginPolicy ?? NativeChargingPolicySnapshot(chargeLimit: monthlyLimit(100, state: 3),
                                             optimizedChargingEnabled: true, optimizedChargingState: overrideOptimized ? 2 : 1)
        if beginFailure { throw NativeChargeLimitError.unavailable }
        return policy
    }
    func restoreAfterTemporaryFullCharge(_ policy: NativeChargingPolicySnapshot) throws -> NativeChargingPolicySnapshot {
        restores.append(policy)
        if restoreFailure { throw NativeChargeLimitError.unavailable }
        if honorsRestores { self.policy = policy }
        return policy
    }
}
