import Combine
import Foundation
import XCTest
@testable import OpenDente

/// Regression coverage uses only injected controls; no XPC connection or SMC writes.
@MainActor
final class ChargingControlRegressionTests: XCTestCase {
    private var settings: AppSettings!
    private var helper: MockChargingControl!
    private var sleep: MockSleepAssertionControl!
    private var manager: ChargingManager!
    private var battery: BatteryService!
    private var timer: ManualChargingTimeout!
    private var suite: String!

    @MainActor
    override func setUp() async throws {
        suite = "com.opendente.tests.control." + UUID().uuidString
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.sailingModeEnabled = false
        settings.heatProtectionEnabled = false
        settings.controlMagSafeLED = false
        settings.showNotifications = false
        settings.stopChargingWhenSleeping = false
        settings.disableSleepUntilChargeLimit = false
        helper = MockChargingControl()
        sleep = MockSleepAssertionControl()
        timer = ManualChargingTimeout()
        manager = makeManager(helper: helper)
    }

    @MainActor
    override func tearDown() async throws {
        manager = nil
        battery = nil
        settings = nil
        helper = nil
        sleep = nil
        timer = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        suite = nil
    }

    private func makeManager(helper: ChargingControl) -> ChargingManager {
        battery = BatteryService(settings: settings)
        battery.batteryState = makeBatteryState()
        let manager = ChargingManager(settings: settings, helper: helper,
                                      battery: battery,
                                      sleepAssertion: sleep, controlTimeout: timer)
        manager.isHelperInstalled = true
        manager.chargingAPI = .legacy
        return manager
    }

    func testHotBatteryStillChargingRetriesInhibitAfterDebounce() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 40))
        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertEqual(helper.calls, [.inhibitCharging])

        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        helper.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 40))

        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertEqual(helper.calls, [.inhibitCharging])
        XCTAssertEqual(manager.inhibitRetryCount, 1)
    }

    func testCooldownBatteryStillChargingRetriesInhibitAfterDebounce() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 40))
        manager.heatProtectionTimer = Date().addingTimeInterval(-30)
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        helper.clearCalls()

        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 33))

        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertEqual(helper.calls, [.inhibitCharging])
        XCTAssertEqual(manager.inhibitRetryCount, 1)
    }

    func testForcedDischargeWithAdapterPresentKeepsSleepAssertion() {
        settings.disableSleepUntilChargeLimit = true
        manager.startDischarge()
        manager.evaluateState(makeBatteryState(percentage: 84, adapterPower: 30))
        XCTAssertTrue(sleep.isPreventingSleep)

        manager.evaluateState(makeBatteryState(percentage: 83, isPluggedIn: false, adapterPower: 30))

        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(sleep.isPreventingSleep)
        XCTAssertTrue(manager.isPreventingSleep)
        manager.evaluateState(makeBatteryState(percentage: 82, isPluggedIn: false, adapterPower: 0))
        XCTAssertFalse(manager.isPreventingSleep)
    }

    func testMissingTemperatureDoesNotCancelActiveHeatCooldown() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35
        manager.evaluateState(makeBatteryState(percentage: 60, temperature: 40))
        XCTAssertEqual(manager.mode, .heatProtection)
        helper.clearCalls()

        // Even an elapsed timer does not prove cooling without a sensor reading.
        manager.heatProtectionTimer = Date().addingTimeInterval(-301)
        manager.evaluateState(makeBatteryState(percentage: 60, temperature: nil))
        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertFalse(helper.calls.contains(.enableCharging))
        XCTAssertNotNil(manager.heatProtectionTimer)

        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 33))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(helper.calls, [.enableCharging])
    }

    func testStopDischargeWithAutomaticDischargeEnabledSurvivesNextPoll() {
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .discharging)
        manager.stopDischarge()
        XCTAssertEqual(manager.mode, .idle)
        helper.clearCalls()

        for _ in 0..<3 { manager.evaluateState(makeBatteryState(percentage: 85)) }

        XCTAssertEqual(manager.mode, .paused)
        XCTAssertFalse(helper.calls.contains(.forceDischarge(enable: true)))
    }

    func testOlderInhibitFailureCannotLoseAutoDischargeTracking() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))

        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertEqual(deferred.calls, [.inhibitCharging],
                       "Force discharge must wait for the previous operation's reply")
        deferred.reply(0, success: false)
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .forceDischarge(true)])
        deferred.reply(1, success: true)
        deferred.reply(0, success: false) // A duplicated late callback cannot erase the new mode.
        XCTAssertEqual(manager.mode, .discharging)

        manager.evaluateState(makeBatteryState(percentage: 79, isPluggedIn: false, adapterPower: 30))
        XCTAssertEqual(deferred.calls.last, .forceDischarge(false))
        deferred.reply(2, success: true)
        XCTAssertNotEqual(manager.mode, .discharging)
    }

    func testDuplicateReplyCannotDrainQueueOrChangeLaterIntent() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        manager.evaluateState(makeBatteryState(percentage: 80))
        manager.startTopUp()
        XCTAssertEqual(deferred.calls, [.inhibitCharging])
        deferred.reply(0, success: true)
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .enableCharging])

        manager.cancelTopUp()
        deferred.reply(0, success: false)
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertEqual(deferred.calls.count, 2)
        deferred.reply(1, success: false) // Older enable fails after cancellation.
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .enableCharging, .inhibitCharging])
        deferred.reply(1, success: true)
        XCTAssertEqual(deferred.calls.count, 3)
        deferred.reply(2, success: true)
        XCTAssertEqual(manager.mode, .idle)
    }

    func testResetSupersedesQueuedDischargeWithoutOvertakingActiveWrite() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.resetToDefaults()
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertEqual(deferred.calls, [.inhibitCharging])

        deferred.reply(0, success: false)
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .reset])
        deferred.reply(0, success: true)
        XCTAssertEqual(deferred.calls.count, 2)
        XCTAssertEqual(manager.mode, .idle)
        deferred.reply(1, success: true)
        XCTAssertFalse(deferred.calls.contains(.forceDischarge(true)))
    }

    func testTerminationResetInvalidatesQueuedWritesAndLateReplies() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.resetToDefaultsSync()
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .resetSync])
        deferred.reply(0, success: false)
        deferred.reply(0, success: true)
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .resetSync])
    }

    func testFailedDischargeStartCleansUpPossiblePartialWriteAndRetriesStop() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        var events: [ChargingEvent] = []
        let subscription = manager.events.sink { events.append($0) }
        defer { subscription.cancel() }

        manager.startDischarge()
        deferred.reply(0, success: false)
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertEqual(deferred.calls, [.forceDischarge(true), .forceDischarge(false)])
        deferred.reply(0, success: true)
        XCTAssertEqual(deferred.calls.count, 2)
        deferred.reply(1, success: false)

        manager.evaluateState(makeBatteryState(percentage: 79, isPluggedIn: false, adapterPower: 30))
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertEqual(deferred.calls.last, .forceDischarge(false))
        XCTAssertFalse(deferred.calls.contains(.enableCharging))
        deferred.reply(2, success: true)
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertTrue(events.isEmpty, "A failed start/cleanup is not discharge completion")
    }

    func testFailedGoalStopRetriesBeforeChargingAndReportsCompletionOnce() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        var events: [ChargingEvent] = []
        let subscription = manager.events.sink { events.append($0) }
        defer { subscription.cancel() }

        manager.startDischarge()
        deferred.reply(0, success: true)
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(deferred.calls, [.forceDischarge(true), .forceDischarge(false)])
        XCTAssertTrue(events.isEmpty, "Reaching the goal is insufficient until discharge is disabled")
        deferred.reply(1, success: false)
        XCTAssertEqual(manager.mode, .discharging)

        manager.evaluateState(makeBatteryState(percentage: 79, isPluggedIn: false, adapterPower: 30))
        manager.startTopUp() // A new enable must not bypass the unresolved discharge stop.
        XCTAssertEqual(deferred.calls.last, .forceDischarge(false))
        XCTAssertFalse(deferred.calls.contains(.enableCharging))
        XCTAssertTrue(events.isEmpty)
        deferred.reply(2, success: true)
        deferred.reply(2, success: true)
        XCTAssertEqual(events, [.dischargeCompleted])
        XCTAssertEqual(manager.mode, .idle)
    }

    func testCancelPendingGoalCompletionSuppressesCompletionEvent() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        var events: [ChargingEvent] = []
        let subscription = manager.events.sink { events.append($0) }
        defer { subscription.cancel() }

        manager.startDischarge()
        deferred.reply(0, success: true)
        manager.evaluateState(makeBatteryState(percentage: 80))
        manager.stopDischarge()
        deferred.reply(1, success: true)
        XCTAssertEqual(deferred.calls.last, .forceDischarge(false))
        XCTAssertTrue(events.isEmpty)
        deferred.reply(2, success: true)
        XCTAssertTrue(events.isEmpty)
    }

    func testStoppingQueuedAutomaticStartNeverEnablesDischarge() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.stopDischarge()
        deferred.reply(0, success: false)

        XCTAssertEqual(deferred.calls, [.inhibitCharging, .forceDischarge(false)])
        deferred.reply(1, success: true)
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(deferred.calls.last, .inhibitCharging)
        XCTAssertFalse(deferred.calls.contains(.forceDischarge(true)))
    }

    func testStopDischargeCancellationSurvivesAdapterPowerSourceFlicker() {
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.stopDischarge()
        helper.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: false, adapterPower: 30))
        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))
        XCTAssertFalse(helper.calls.contains(.forceDischarge(enable: true)))

        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: false, adapterPower: 0))
        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(helper.calls.contains(.forceDischarge(enable: true)))
    }

    func testStopDischargeCancellationSurvivesUnknownAdapterPower() {
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.stopDischarge()
        helper.clearCalls()

        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: false, adapterPower: nil))
        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))

        XCTAssertEqual(manager.mode, .paused)
        XCTAssertFalse(helper.calls.contains(.forceDischarge(enable: true)),
                       "A failed adapter reading must not reset the user's cancellation")
    }

    func testUnknownAdapterPowerRetainsDischargeAndSleepUntilGoal() {
        settings.disableSleepUntilChargeLimit = true
        manager.startDischarge()
        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))
        helper.clearCalls()

        manager.evaluateState(makeBatteryState(percentage: 84, isPluggedIn: false, adapterPower: nil))
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(manager.isPreventingSleep)
        XCTAssertTrue(helper.calls.isEmpty)

        manager.evaluateState(makeBatteryState(percentage: 80, isPluggedIn: false, adapterPower: nil))
        XCTAssertTrue(helper.calls.contains(.forceDischarge(enable: false)),
                      "Unknown adapter power must not bypass the charge-limit stop")
        XCTAssertFalse(manager.isPreventingSleep)
    }

    func testAutomaticDischargeCanRestartAfterSettingIsToggledOrManualStart() {
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.stopDischarge()
        settings.automaticDischarge = false
        manager.evaluateState(makeBatteryState(percentage: 85))
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .discharging)

        manager.stopDischarge()
        helper.clearCalls()
        manager.startDischarge()
        XCTAssertEqual(helper.calls, [.forceDischarge(enable: true)])
    }

    func testTopUpStartEventPrecedesModeIncludingRepeatedStart() {
        var modesAtStart: [ChargingMode] = []
        let target = manager!
        let subscription = target.events.sink { event in
            if event == .topUpStarted { modesAtStart.append(target.mode) }
        }
        defer { subscription.cancel() }
        manager.startTopUp()
        manager.startTopUp()
        XCTAssertEqual(modesAtStart, [.idle, .topUp])
        XCTAssertEqual(helper.calls, [.enableCharging, .enableCharging])
    }

    func testHeatProtectionFailureAndMissingSensorContinueVerificationWithRetryLimit() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35
        helper.shouldFail = true
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 40))
        XCTAssertEqual(manager.mode, .heatProtection)
        for retry in 1...3 {
            manager.lastInhibitTime = Date().addingTimeInterval(-16)
            manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: nil))
            XCTAssertEqual(manager.inhibitRetryCount, retry)
            XCTAssertEqual(manager.mode, .heatProtection)
        }
        let attempts = helper.calls.count
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: nil))
        XCTAssertTrue(manager.didNotifyInhibitExhausted)
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: nil))
        XCTAssertEqual(helper.calls.count, attempts)
        XCTAssertFalse(helper.calls.contains(.enableCharging))
    }

    func testUnansweredInhibitDoesNotQueueMultipleVerificationRetries() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: 40))
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        for _ in 0..<5 {
            manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: nil))
        }
        XCTAssertEqual(deferred.calls, [.inhibitCharging])
        XCTAssertEqual(manager.inhibitRetryCount, 0)
        deferred.reply(0, success: true)
        manager.evaluateState(makeBatteryState(percentage: 60, isCharging: true, temperature: nil))
        XCTAssertEqual(deferred.calls, [.inhibitCharging, .inhibitCharging])
        XCTAssertEqual(manager.inhibitRetryCount, 1)
    }

    func testWakeDoesNotRestartDischargeWhileFailedStopNeedsRetry() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        manager.startDischarge()
        deferred.reply(0, success: true)
        manager.handleWillSleep()
        deferred.reply(1, success: false)

        manager.handleDidWake(makeBatteryState(percentage: 85, isPluggedIn: false, adapterPower: 30))

        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertEqual(deferred.calls, [.forceDischarge(true), .forceDischarge(false), .forceDischarge(false)])
        deferred.reply(2, success: true)
        XCTAssertEqual(manager.mode, .onBattery)
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertFalse(deferred.calls.dropFirst().contains(.forceDischarge(true)))
    }

    func testLostInhibitReplyTimesOutAndCannotAffectNextDischarge() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(timer.delay, 15)
        timer.fire()

        XCTAssertEqual(deferred.calls, [.inhibitCharging, .forceDischarge(true)])
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(timer.isScheduled)
        deferred.reply(0, success: false)
        timer.fireScheduled(0) // An already enqueued timeout is stale too.
        XCTAssertTrue(timer.isScheduled)
        XCTAssertEqual(deferred.calls.count, 2)
        deferred.reply(1, success: true)
        XCTAssertFalse(timer.isScheduled)
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(deferred.calls.last, .forceDischarge(false))
    }

    func testLostDischargeReplyTimesOutAndClearsPossiblePartialWrite() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        manager.startDischarge()
        timer.fire()

        XCTAssertEqual(deferred.calls, [.forceDischarge(true), .forceDischarge(false)])
        XCTAssertEqual(manager.mode, .discharging)
        deferred.reply(0, success: true)
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(timer.isScheduled)
        deferred.reply(1, success: true)
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertFalse(timer.isScheduled)
    }

    func testLostResetReplyRetriesDischargeCleanupWithoutRestartingIt() {
        let deferred = DeferredChargingControl()
        manager = makeManager(helper: deferred)
        manager.startDischarge()
        deferred.reply(0, success: true)
        manager.resetToDefaults()
        timer.fire()

        XCTAssertEqual(manager.mode, .discharging)
        manager.startTopUp()
        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: false, adapterPower: 30))
        XCTAssertEqual(deferred.calls, [.forceDischarge(true), .reset, .forceDischarge(false)])
        deferred.reply(1, success: true)
        XCTAssertTrue(timer.isScheduled, "A late reset reply cannot cancel the current stop's timer")
        deferred.reply(2, success: true)
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertFalse(timer.isScheduled)
    }

    func testInvalidBatterySnapshotPreservesPausedGateAndVerificationState() {
        manager.evaluateState(makeBatteryState(percentage: 80))
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        let previousInhibitTime = manager.lastInhibitTime
        helper.clearCalls()
        var invalid = makeBatteryState(percentage: 0, isCharging: true, isPluggedIn: false)
        invalid.hasValidBatteryReading = false

        manager.evaluateState(invalid)

        XCTAssertEqual(manager.mode, .paused)
        XCTAssertEqual(manager.lastInhibitTime, previousInhibitTime)
        XCTAssertEqual(manager.inhibitRetryCount, 0)
        XCTAssertFalse(manager.lastIsCharging)
        XCTAssertTrue(helper.calls.isEmpty)
    }

    func testInvalidBatterySnapshotPreservesDischargeTrackingAndSleepAssertion() {
        settings.disableSleepUntilChargeLimit = true
        manager.startDischarge()
        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))
        helper.clearCalls()
        var invalid = makeBatteryState(percentage: 0, isPluggedIn: false, adapterPower: 0)
        invalid.hasValidBatteryReading = false

        manager.evaluateState(invalid)

        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(manager.isPreventingSleep)
        XCTAssertTrue(helper.calls.isEmpty, "Unknown IOPS data must not imitate reaching the goal or unplugging")
        manager.evaluateState(makeBatteryState(percentage: 80, isPluggedIn: false, adapterPower: 30))
        XCTAssertTrue(helper.calls.contains(.forceDischarge(enable: false)))
        XCTAssertFalse(manager.isPreventingSleep)
    }

    func testInvalidBatterySnapshotPreservesThermalHold() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35
        manager.evaluateState(makeBatteryState(percentage: 60, temperature: 40))
        let previousTimer = manager.heatProtectionTimer
        helper.clearCalls()
        var invalid = makeBatteryState(percentage: 0, isPluggedIn: true, temperature: 25)
        invalid.hasValidBatteryReading = false

        manager.evaluateState(invalid)

        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertEqual(manager.heatProtectionTimer, previousTimer)
        XCTAssertTrue(helper.calls.isEmpty)
    }

    func testInvalidBatterySnapshotDoesNotClearAutomaticDischargeCancellation() {
        settings.automaticDischarge = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        manager.stopDischarge()
        helper.clearCalls()
        var invalid = makeBatteryState(percentage: 0, isPluggedIn: false, adapterPower: 0)
        invalid.hasValidBatteryReading = false

        manager.evaluateState(invalid)
        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))

        XCTAssertEqual(manager.mode, .paused)
        XCTAssertFalse(helper.calls.contains(.forceDischarge(enable: true)))
    }

    func testWakeDefersResyncUntilBatterySnapshotIsValid() {
        manager.startDischarge()
        manager.handleWillSleep()
        helper.clearCalls()
        var invalid = makeBatteryState(percentage: 0, isPluggedIn: false, adapterPower: 0)
        invalid.hasValidBatteryReading = false

        manager.handleDidWake(invalid)
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertEqual(manager.modeBeforeSleep, .discharging)
        XCTAssertTrue(helper.calls.isEmpty)

        manager.evaluateState(makeBatteryState(percentage: 85, adapterPower: 30))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertNil(manager.modeBeforeSleep)
        XCTAssertEqual(helper.calls, [.inhibitCharging])
    }

    func testInvalidEvaluatedReadingBlocksNewActionsButAllowsStopAndReset() {
        var invalid = makeBatteryState(percentage: 0, isPluggedIn: true)
        invalid.hasValidBatteryReading = false
        manager.evaluateState(invalid)
        manager.startTopUp()
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertTrue(helper.calls.isEmpty)

        manager.stopDischarge()
        manager.resetToDefaults()
        XCTAssertEqual(helper.calls, [.forceDischarge(enable: false), .resetToDefaults])

        helper.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 80))
        manager.startTopUp()
        XCTAssertEqual(manager.mode, .topUp)
        XCTAssertEqual(helper.calls, [.inhibitCharging, .enableCharging])
    }

    func testUnprocessedInvalidServiceReadingAlsoBlocksManualStart() {
        var invalid = makeBatteryState(percentage: 0, isPluggedIn: true)
        invalid.hasValidBatteryReading = false
        battery.batteryState = invalid
        manager.startTopUp()
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertTrue(helper.calls.isEmpty,
                      "A click before the next evaluation must not use the service's invalid snapshot")
    }

    func testValidZeroPercentWithoutTimeEstimatesStopsTrackedDischarge() {
        manager.startDischarge()
        helper.clearCalls()
        let empty = makeBatteryState(percentage: 0, isPluggedIn: false, adapterPower: 30)
        XCTAssertTrue(empty.hasValidBatteryReading)
        XCTAssertNil(empty.timeToEmpty)
        XCTAssertNil(empty.timeToFull)

        manager.evaluateState(empty)

        XCTAssertTrue(helper.calls.contains(.forceDischarge(enable: false)),
                      "A valid 0% reading must clear discharge at the goal instead of being ignored as startup data")
        XCTAssertNotEqual(manager.mode, .discharging)
    }
}

@MainActor
private final class ManualChargingTimeout: ChargingOperationTimeoutControl {
    private var active: (@MainActor @Sendable () -> Void)?
    private var scheduled: [@MainActor @Sendable () -> Void] = []
    private(set) var delay: TimeInterval?
    var isScheduled: Bool { active != nil }

    func schedule(after seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        delay = seconds
        active = action
        scheduled.append(action)
    }
    func cancel() { active = nil }
    func fire() {
        let action = active
        active = nil
        action?()
    }
    func fireScheduled(_ index: Int) { scheduled[index]() }
}

/// Call storage and retained replies are protected by one lock. Retaining replies
/// deliberately lets tests deliver duplicates and out-of-order XPC callbacks.
private final class DeferredChargingControl: ChargingControl, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case enableCharging
        case inhibitCharging
        case forceDischarge(Bool)
        case reset
        case resetSync
    }
    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var replies: [(@Sendable (Bool, String?) -> Void)?] = []

    var calls: [Call] { lock.withLock { recordedCalls } }

    func reply(_ index: Int, success: Bool) {
        let completion = lock.withLock { replies[index] }
        completion?(success, success ? nil : "simulated partial failure")
    }

    private func record(_ call: Call, completion: (@Sendable (Bool, String?) -> Void)?) {
        lock.withLock {
            recordedCalls.append(call)
            replies.append(completion)
        }
    }

    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)?) {
        record(.enableCharging, completion: completion)
    }
    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)?) {
        record(.inhibitCharging, completion: completion)
    }
    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)?) {
        record(.forceDischarge(enable), completion: completion)
    }
    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)?) {
        record(.reset, completion: completion)
    }
    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)?) {
        completion?(true, nil)
    }
    nonisolated func resetToDefaultsSync(timeout: TimeInterval) {
        record(.resetSync, completion: nil)
    }
}
