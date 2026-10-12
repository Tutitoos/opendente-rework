import Foundation
import Testing
@testable import OpenDente

@Suite("Native charging manager")
@MainActor
struct NativeChargingManagerTests {
    @Test func startupAdoptsNativeLimitWithoutApplyingOldAppPreference() {
        let fixture = NativeManagerFixture(nativeLimit: 90, savedLimit: 80)
        defer { fixture.cleanUp() }
        fixture.manager.start()

        #expect(!fixture.manager.isHelperInstalled)
        #expect(fixture.manager.isUsingNativeChargeLimit)
        #expect(fixture.manager.canControlChargeLimit)
        #expect(!fixture.manager.supportsSMCControls)
        #expect(fixture.manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.settings.chargeLimit == 90)
        #expect(fixture.settings.legacySMCChargeLimit == 80)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.helper.calls.isEmpty)
    }

    @Test func unsupportedSavedLimitPreservesActualWithoutRaisingDesired() async {
        let fixture = NativeManagerFixture(nativeLimit: 90, savedLimit: 60)
        defer { fixture.cleanUp() }
        fixture.manager.start()
        await drainNativeManagerRunLoop()
        fixture.manager.evaluateState(makeBatteryState(percentage: 90))
        await drainNativeManagerRunLoop()

        #expect(fixture.manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.settings.chargeLimit == 90)
        #expect(fixture.settings.legacySMCChargeLimit == 60)
        #expect(fixture.manager.nativeChargeLimitError == nil)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.helper.calls.isEmpty)

        #expect(fixture.manager.setChargeLimit(85))
        #expect(fixture.settings.chargeLimit == 85)
        #expect(fixture.manager.effectiveNativeChargeLimit == 85)
        #expect(fixture.manager.nativeChargeLimitError == nil)
    }

    @Test func realSettingsObserverApplies100ThenExplicit80WithoutFeedback() async {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.start()
        await drainNativeManagerRunLoop()
        fixture.settings.chargeLimit = 100
        await drainNativeManagerRunLoop()
        await drainNativeManagerRunLoop()

        #expect(fixture.native.writes == [100])
        #expect(!fixture.native.snapshot.enabled)
        #expect(fixture.manager.effectiveNativeChargeLimit == 100)
        #expect(fixture.settings.chargeLimit == 100)

        #expect(fixture.manager.setChargeLimit(80))
        await drainNativeManagerRunLoop()
        await drainNativeManagerRunLoop()
        #expect(fixture.native.writes == [100, 80])
        #expect(fixture.native.snapshot.enabled)
        #expect(fixture.manager.effectiveNativeChargeLimit == 80)
        #expect(fixture.settings.chargeLimit == 80)
        #expect(fixture.helper.calls.isEmpty)
    }

    @Test func pollingAdoptsExternalLimitWithoutDeferredFeedbackWrite() async {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.start()
        await drainNativeManagerRunLoop()
        fixture.native.snapshot = nativeSnapshot(limit: 95)
        fixture.battery.batteryState = makeBatteryState(percentage: 80, isCharging: true)
        await drainNativeManagerRunLoop()
        await drainNativeManagerRunLoop()

        #expect(fixture.settings.chargeLimit == 95)
        #expect(fixture.manager.effectiveNativeChargeLimit == 95)
        #expect(fixture.manager.mode == .charging)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.helper.calls.isEmpty)

        fixture.native.snapshot = nativeSnapshot(limit: 80, enabled: false)
        fixture.battery.batteryState = makeBatteryState(percentage: 85, isCharging: true)
        await drainNativeManagerRunLoop()
        await drainNativeManagerRunLoop()
        #expect(fixture.settings.chargeLimit == 100)
        #expect(fixture.manager.effectiveNativeChargeLimit == 100)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func failedWriteReconcilesActualAndPreservesErrorAcrossPolls() async {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.start()
        await drainNativeManagerRunLoop()
        fixture.native.honorsWrites = false
        fixture.native.writeError = NativeChargeLimitError.unavailable
        fixture.settings.chargeLimit = 90
        await drainNativeManagerRunLoop()
        await drainNativeManagerRunLoop()

        #expect(fixture.native.writes == [90])
        #expect(fixture.manager.effectiveNativeChargeLimit == 80)
        #expect(fixture.settings.chargeLimit == 80)
        #expect(fixture.manager.nativeChargeLimitError != nil)
        fixture.manager.evaluateState(makeBatteryState(percentage: 80))
        await drainNativeManagerRunLoop()
        #expect(fixture.native.writes == [90])
        #expect(fixture.manager.nativeChargeLimitError != nil)

        fixture.native.writeError = nil
        fixture.native.honorsWrites = true
        #expect(fixture.manager.setChargeLimit(90))
        #expect(fixture.manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.manager.nativeChargeLimitError == nil)
    }

    @Test func partialWriteFailureDisplaysReconciledActualInsteadOfRequested() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        fixture.native.stateAfterWrite = nativeSnapshot(limit: 85)
        fixture.native.writeError = NativeChargeLimitError.unavailable

        #expect(!fixture.manager.setChargeLimit(95))
        #expect(fixture.manager.effectiveNativeChargeLimit == 85)
        #expect(fixture.settings.chargeLimit == 85)
        #expect(fixture.manager.nativeChargeLimitError?.contains("95%") == true)
        #expect(fixture.helper.calls.isEmpty)
    }

    @Test func successfulReplyWithoutMatchingReadbackCannotClaimRequestedLimit() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        fixture.native.honorsWrites = false
        fixture.native.replyOverride = nativeSnapshot(limit: 90)

        #expect(!fixture.manager.setChargeLimit(90))
        #expect(fixture.manager.effectiveNativeChargeLimit == 80)
        #expect(fixture.settings.chargeLimit == 80)
        #expect(fixture.manager.nativeChargeLimitError != nil)
    }

    @Test func requesting100RequiresDisabledNativePolicyRatherThanEnabled100() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        fixture.native.stateAfterWrite = nativeSnapshot(limit: 100, enabled: true)

        #expect(!fixture.manager.setChargeLimit(100))
        #expect(fixture.manager.nativeChargeLimitError?.contains("enabled: true") == true)
        #expect(fixture.native.snapshot.enabled)
    }

    @Test func disabledPolicyWithUnsetStoredLimitIsEffective100() {
        let fixture = NativeManagerFixture(nativeLimit: 0, savedLimit: 100, enabled: false)
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()

        #expect(fixture.manager.canControlChargeLimit)
        #expect(fixture.manager.effectiveNativeChargeLimit == 100)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func readFailureDisablesControlAndRecoveryAdoptsActualWithoutStaleWrite() async {
        let fixture = NativeManagerFixture(nativeLimit: 80, savedLimit: 90)
        defer { fixture.cleanUp() }
        fixture.native.readError = NativeChargeLimitError.unavailable
        fixture.manager.start()
        await drainNativeManagerRunLoop()
        #expect(fixture.manager.isUsingNativeChargeLimit)
        #expect(!fixture.manager.canControlChargeLimit)
        #expect(fixture.manager.effectiveNativeChargeLimit == nil)
        #expect(fixture.manager.nativeChargeLimitError != nil)

        fixture.native.readError = nil
        fixture.native.snapshot = nativeSnapshot(limit: 95)
        fixture.battery.batteryState = makeBatteryState(percentage: 70, isCharging: true)
        await drainNativeManagerRunLoop()
        await drainNativeManagerRunLoop()
        #expect(fixture.manager.canControlChargeLimit)
        #expect(fixture.manager.effectiveNativeChargeLimit == 95)
        #expect(fixture.settings.chargeLimit == 95)
        #expect(fixture.manager.nativeChargeLimitError == nil)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.helper.calls.isEmpty)
    }

    @Test func laterReadFailureClearsPreviouslyKnownEffectiveLimit() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        fixture.native.readError = NativeChargeLimitError.unavailable
        fixture.manager.refreshNativeChargeLimit()
        #expect(fixture.manager.effectiveNativeChargeLimit == nil)
        #expect(fixture.manager.availableNativeChargeLimits.isEmpty)
        #expect(!fixture.manager.canControlChargeLimit)
        #expect(fixture.manager.nativeChargeLimitError != nil)
        #expect(!fixture.manager.setChargeLimit(90))
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func readbackFailureReconcilesButKeepsOperationError() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        // Explicit change first refreshes, then writes, then reads independently.
        fixture.native.failedReadNumbers = [fixture.native.readCount + 2]
        #expect(!fixture.manager.setChargeLimit(90))
        #expect(fixture.manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.settings.chargeLimit == 90)
        #expect(fixture.manager.nativeChargeLimitError != nil)
    }

    @Test func nativeObservedModesBypassAllEnabledSMCPreferencesAndManualActions() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.isHelperInstalled = true
        fixture.manager.helperVersion = "1.4.0"
        fixture.manager.initializeNativeChargeLimit()

        fixture.manager.evaluateState(makeBatteryState(percentage: 95, isCharging: true, temperature: 45))
        #expect(fixture.manager.mode == .charging)
        fixture.manager.evaluateState(makeBatteryState(percentage: 80, temperature: 45))
        #expect(fixture.manager.mode == .paused)
        fixture.manager.evaluateState(makeBatteryState(percentage: 70, temperature: 45))
        #expect(fixture.manager.mode == .idle)
        fixture.manager.evaluateState(makeBatteryState(percentage: 70, isPluggedIn: false, temperature: 45))
        #expect(fixture.manager.mode == .onBattery)
        fixture.manager.startDischarge()
        fixture.manager.stopDischarge()
        fixture.manager.startTopUp()
        fixture.manager.cancelTopUp()
        fixture.manager.pauseCharging()

        #expect(!fixture.manager.supportsSMCControls)
        #expect(!fixture.manager.isPreventingSleep)
        #expect(fixture.sleep.preventSleepCallCount == 0)
        #expect(fixture.helper.calls.isEmpty)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func nativeLimitPersistsThroughSleepWakeResetAndQuit() {
        let fixture = NativeManagerFixture(nativeLimit: 90, savedLimit: 90)
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        fixture.manager.handleWillSleep()
        fixture.manager.handleDidWake(makeBatteryState(percentage: 80, isCharging: true))
        fixture.manager.resetToDefaults()
        fixture.manager.resetToDefaultsSync()

        #expect(fixture.native.snapshot == nativeSnapshot(limit: 90))
        #expect(fixture.manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.helper.calls.isEmpty)
    }

    @Test func invalidBatterySnapshotStillReadsNativePolicyWithoutInventedMode() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.manager.initializeNativeChargeLimit()
        fixture.manager.evaluateState(makeBatteryState(percentage: 70, isCharging: true))
        fixture.native.snapshot = nativeSnapshot(limit: 90)
        fixture.manager.handleDidWake(.unknown)

        #expect(fixture.manager.mode == .charging)
        #expect(fixture.manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.settings.chargeLimit == 90)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.helper.calls.isEmpty)
    }

    @Test func nativeBackendTakesPriorityEvenWhenSMCIsSupported() {
        let fixture = NativeManagerFixture(smcAPI: .legacy)
        defer { fixture.cleanUp() }
        fixture.manager.isHelperInstalled = true
        fixture.manager.start()

        #expect(!fixture.manager.supportsSMCControls)
        #expect(fixture.manager.isUsingNativeChargeLimit)
        #expect(fixture.native.readCount > 0)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func initialUnsupportedNativeBackendRetainsSMCFallback() {
        let fixture = NativeManagerFixture(smcAPI: .legacy)
        defer { fixture.cleanUp() }
        fixture.native.readError = NativeChargeLimitError.unavailable
        fixture.manager.isHelperInstalled = true
        fixture.manager.start()
        #expect(fixture.manager.supportsSMCControls)
        #expect(!fixture.manager.isUsingNativeChargeLimit)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func transientNativeReadFailureNeverEnablesSMCWrites() {
        let fixture = NativeManagerFixture(smcAPI: .legacy)
        defer { fixture.cleanUp() }
        fixture.manager.isHelperInstalled = true
        fixture.manager.start()
        fixture.native.readError = NativeChargeLimitError.unavailable
        fixture.manager.evaluateState(makeBatteryState(percentage: 20))
        #expect(fixture.manager.isUsingNativeChargeLimit)
        #expect(!fixture.manager.supportsSMCControls)
        #expect(fixture.helper.calls.isEmpty)
        #expect(!fixture.manager.canControlChargeLimit)
    }

    @Test func initialNativeReadErrorDoesNotMistakeAnUnknownPolicyForUnsupportedHardware() {
        let fixture = NativeManagerFixture(smcAPI: .legacy)
        defer { fixture.cleanUp() }
        fixture.native.readError = NSError(domain: "PowerUI", code: 42)
        fixture.manager.isHelperInstalled = true
        fixture.manager.start()
        #expect(fixture.manager.isUsingNativeChargeLimit)
        #expect(!fixture.manager.supportsSMCControls)
        #expect(fixture.helper.calls.isEmpty)
        #expect(!fixture.manager.canControlChargeLimit)
    }

    @Test func fallbackOwnInhibitionIsReleasedOnceBeforeNativeControl() {
        let fixture = NativeManagerFixture(smcAPI: .legacy)
        defer { fixture.cleanUp() }
        disableNativeFixtureLegacyExtras(fixture.settings)
        fixture.native.readError = NativeChargeLimitError.unavailable
        fixture.manager.isHelperInstalled = true
        fixture.manager.start()
        #expect(fixture.helper.calls == [.inhibit])

        fixture.native.readError = nil
        fixture.manager.refreshNativeChargeLimit()
        #expect(fixture.manager.isUsingNativeChargeLimit)
        #expect(!fixture.manager.isReleasingSMCForNative)
        #expect(fixture.manager.canControlChargeLimit)
        #expect(fixture.helper.calls == [.inhibit, .enable])
        fixture.manager.refreshNativeChargeLimit()
        #expect(fixture.helper.calls == [.inhibit, .enable])
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func nativeHandoffWaitsForOwnSMCWriteThenVerifiedRelease() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        disableNativeFixtureLegacyExtras(fixture.settings)
        let helper = NativeDeferredSMCControl()
        fixture.native.readError = NativeChargeLimitError.unavailable
        let manager = ChargingManager(settings: fixture.settings, helper: helper, battery: fixture.battery,
                                      sleepAssertion: fixture.sleep, nativeChargeLimitControl: fixture.native)
        manager.chargingAPI = .legacy
        manager.isHelperInstalled = true
        manager.evaluateState(makeBatteryState(percentage: 80))
        #expect(helper.calls == [.inhibit])
        fixture.native.readError = nil
        manager.refreshNativeChargeLimit()
        #expect(manager.isReleasingSMCForNative)
        #expect(!manager.canControlChargeLimit)
        fixture.native.optimized = true
        manager.refreshNativeChargingPolicy()
        #expect(!manager.canControlOptimizedCharging)
        #expect(!manager.setOptimizedChargingEnabled(false))
        #expect(fixture.native.optimizedWrites.isEmpty)
        #expect(helper.calls == [.inhibit])

        helper.reply(0, success: true)
        #expect(helper.calls == [.inhibit, .enable])
        #expect(!manager.setChargeLimit(90))
        helper.reply(1, success: true)
        #expect(!manager.isReleasingSMCForNative)
        #expect(manager.canControlChargeLimit)
        #expect(manager.canControlOptimizedCharging)
        #expect(fixture.native.writes.isEmpty)
        #expect(manager.setChargeLimit(90))
    }

    @Test func failedOwnSMCReleaseBlocksNativeWritesAndRetriesOnlyExplicitly() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        disableNativeFixtureLegacyExtras(fixture.settings)
        let helper = NativeDeferredSMCControl()
        fixture.native.readError = NativeChargeLimitError.unavailable
        let manager = ChargingManager(settings: fixture.settings, helper: helper, battery: fixture.battery,
                                      sleepAssertion: fixture.sleep, nativeChargeLimitControl: fixture.native)
        manager.chargingAPI = .legacy
        manager.isHelperInstalled = true
        manager.evaluateState(makeBatteryState(percentage: 80))
        helper.reply(0, success: true)
        fixture.native.readError = nil
        manager.refreshNativeChargeLimit()
        helper.reply(1, success: false)
        #expect(manager.isReleasingSMCForNative)
        #expect(!manager.canControlChargeLimit)
        #expect(manager.nativeChargeLimitError != nil)
        #expect(!manager.setChargeLimit(90))
        manager.refreshNativeChargeLimit()
        #expect(helper.calls == [.inhibit, .enable])
        #expect(fixture.native.writes.isEmpty)

        manager.retryNativeSMCRelease()
        #expect(helper.calls == [.inhibit, .enable, .enable])
        helper.reply(2, success: true)
        #expect(!manager.isReleasingSMCForNative)
        #expect(manager.nativeChargeLimitError == nil)
        #expect(manager.canControlChargeLimit)
    }

    @Test func returningToNativeInvalidatesOldSMCReplyAndQueuedWrite() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        let deferred = NativeDeferredSMCControl()
        let manager = ChargingManager(settings: fixture.settings, helper: deferred,
                                      battery: fixture.battery, sleepAssertion: fixture.sleep,
                                      nativeChargeLimitControl: fixture.native)
        // An unsupported first discovery may fall back to SMC; hold its enable
        // reply while a later pause waits in FIFO.
        fixture.native.readError = NativeChargeLimitError.unavailable
        manager.chargingAPI = .legacy
        manager.isHelperInstalled = true
        fixture.settings.heatProtectionEnabled = false
        fixture.settings.sailingModeEnabled = false
        fixture.settings.automaticDischarge = false
        fixture.settings.controlMagSafeLED = false
        fixture.settings.disableSleepUntilChargeLimit = false
        manager.evaluateState(makeBatteryState(percentage: 50, isCharging: true))
        manager.pauseCharging()
        #expect(deferred.calls == [.enable])

        // Native was already initialized, but this new entry must still clear
        // the old queue/IDs. Refresh adopts a changed limit without reapplying 80.
        fixture.native.readError = nil
        fixture.native.snapshot = nativeSnapshot(limit: 90)
        manager.chargingAPI = .unknown
        manager.initializeNativeChargeLimit()
        manager.evaluateState(makeBatteryState(percentage: 90))
        deferred.reply(0, success: false)
        deferred.reply(0, success: true)

        #expect(manager.isUsingNativeChargeLimit)
        #expect(!manager.supportsSMCControls)
        #expect(manager.effectiveNativeChargeLimit == 90)
        #expect(fixture.settings.chargeLimit == 90)
        #expect(manager.mode == .paused)
        #expect(deferred.calls == [.enable])
        #expect(fixture.native.writes.isEmpty)
    }

    @Test(arguments: [[60, 80, 100], [80, 80, 100], [80, 90]])
    func malformedNativeSnapshotCannotBecomeUsable(available: [Int]) {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.native.snapshot = NativeChargeLimitSnapshot(availableLimits: available, limit: 80, enabled: true)
        fixture.manager.initializeNativeChargeLimit()
        #expect(!fixture.manager.canControlChargeLimit)
        #expect(fixture.manager.effectiveNativeChargeLimit == nil)
        #expect(fixture.manager.nativeChargeLimitError != nil)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func dynamicAvailableLimitIsUsedRatherThanAssumingFivePointSteps() {
        let fixture = NativeManagerFixture(savedLimit: 81)
        defer { fixture.cleanUp() }
        fixture.native.snapshot = NativeChargeLimitSnapshot(availableLimits: [80, 81, 100], limit: 80, enabled: true)
        fixture.manager.initializeNativeChargeLimit()
        #expect(fixture.manager.effectiveNativeChargeLimit == 80)
        #expect(fixture.manager.availableNativeChargeLimits == [80, 81, 100])
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.manager.setChargeLimit(81))
        #expect(fixture.manager.effectiveNativeChargeLimit == 81)
        #expect(fixture.native.writes == [81])
    }

    @Test func optimizedChargingHasIndependentControlAndReadback() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.native.optimized = true
        fixture.manager.initializeNativeChargeLimit()
        #expect(fixture.manager.canControlOptimizedCharging)
        #expect(fixture.manager.optimizedChargingEnabled == true)
        #expect(fixture.manager.setOptimizedChargingEnabled(false))
        #expect(fixture.manager.optimizedChargingEnabled == false)
        #expect(fixture.native.writes.isEmpty)
        #expect(fixture.manager.setChargeLimit(90))
        #expect(fixture.native.optimized == false)
        #expect(fixture.native.optimizedWrites == [false])
    }

    @Test func optimizedReplyWithoutIndependentMatchingReadbackFails() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.native.optimized = true
        fixture.native.honorsOptimizedWrites = false
        fixture.manager.initializeNativeChargeLimit()
        #expect(!fixture.manager.setOptimizedChargingEnabled(false))
        #expect(fixture.manager.optimizedChargingEnabled == true)
        #expect(fixture.manager.optimizedChargingError != nil)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func nativeTemporaryPolicyDoesNotOverwriteHabitualMonthlyLimit() {
        let fixture = NativeManagerFixture(nativeLimit: 80)
        defer { fixture.cleanUp() }
        let previous = NativeChargingPolicySnapshot(chargeLimit: nativeSnapshot(limit: 80), optimizedChargingEnabled: true)
        fixture.settings.monthlyFullChargeCycle = MonthlyFullChargeCycle(id: UUID(), startedAt: Date(), previousPolicy: previous,
                                                                        temporaryPolicy: nil, reachedFullAt: nil, restorationPending: false)
        fixture.native.snapshot = NativeChargeLimitSnapshot(availableLimits: [80, 85, 90, 95, 100], limit: 100,
                                                           enabled: false, nativeFeatureState: 3)
        fixture.manager.initializeNativeChargeLimit()
        #expect(fixture.manager.effectiveNativeChargeLimit == 100)
        #expect(fixture.manager.isNativeChargeLimitTemporarilyOverridden)
        #expect(fixture.settings.chargeLimit == 80)
        #expect(fixture.native.writes.isEmpty)
    }

    @Test func confirmedTemporaryFlagClearsWhenNativeReadIsLost() {
        let fixture = NativeManagerFixture()
        defer { fixture.cleanUp() }
        fixture.native.snapshot = NativeChargeLimitSnapshot(availableLimits: [80, 85, 90, 95, 100], limit: 100,
                                                           enabled: false, nativeFeatureState: 3)
        fixture.manager.initializeNativeChargeLimit()
        #expect(fixture.manager.isNativeChargeLimitTemporarilyOverridden)
        fixture.native.readError = NativeChargeLimitError.unavailable
        fixture.manager.refreshNativeChargeLimit()
        #expect(!fixture.manager.isNativeChargeLimitTemporarilyOverridden)
        #expect(fixture.manager.effectiveNativeChargeLimit == nil)
        fixture.native.readError = nil
        fixture.native.snapshot = nativeSnapshot(limit: 100, enabled: false)
        fixture.manager.refreshNativeChargeLimit()
        #expect(!fixture.manager.isNativeChargeLimitTemporarilyOverridden)
    }

    @Test func unreadableRecoveryRecordCannotAdoptTemporary100AsHabitual() {
        let fixture = NativeManagerFixture(savedLimit: 80)
        defer { fixture.cleanUp() }
        fixture.settings.monthlyChargeRecoveryUnknown = true
        fixture.native.snapshot = NativeChargeLimitSnapshot(availableLimits: [80, 85, 90, 95, 100], limit: 100,
                                                           enabled: false, nativeFeatureState: 3)
        fixture.manager.initializeNativeChargeLimit()
        #expect(fixture.settings.chargeLimit == 80)
        #expect(fixture.manager.effectiveNativeChargeLimit == 100)
        #expect(fixture.manager.isNativeChargeLimitTemporarilyOverridden)
        #expect(fixture.native.writes.isEmpty)
    }
}

private func nativeSnapshot(limit: Int, enabled: Bool = true) -> NativeChargeLimitSnapshot {
    NativeChargeLimitSnapshot(availableLimits: [80, 85, 90, 95, 100], limit: limit, enabled: enabled)
}

@MainActor
private func disableNativeFixtureLegacyExtras(_ settings: AppSettings) {
    settings.sailingModeEnabled = false
    settings.automaticDischarge = false
    settings.heatProtectionEnabled = false
    settings.controlMagSafeLED = false
    settings.disableSleepUntilChargeLimit = false
}

@MainActor
private func drainNativeManagerRunLoop() async {
    await withCheckedContinuation { continuation in
        RunLoop.main.perform { continuation.resume() }
    }
}

@MainActor
private final class NativeManagerFixture {
    let suite: String
    let settings: AppSettings
    let native: NativeLimitMock
    let helper: NativeSMCRecordingControl
    let sleep: MockSleepAssertionControl
    let battery: BatteryService
    let manager: ChargingManager

    init(nativeLimit: Int = 80, savedLimit: Int = 80, enabled: Bool = true,
         smcAPI: SMCChargingAPI = .unknown) {
        let suite = "com.opendente.tests.native-manager." + UUID().uuidString
        self.suite = suite
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        self.settings = settings
        settings.chargeLimit = savedLimit
        settings.showNotifications = false
        // Every incompatible policy is on to catch accidental legacy evaluation.
        settings.sailingModeEnabled = true
        settings.automaticDischarge = true
        settings.heatProtectionEnabled = true
        settings.controlMagSafeLED = true
        settings.disableSleepUntilChargeLimit = true
        settings.stopChargingWhenSleeping = true
        let native = NativeLimitMock(snapshot: nativeSnapshot(limit: nativeLimit, enabled: enabled))
        self.native = native
        let helper = NativeSMCRecordingControl()
        self.helper = helper
        let sleep = MockSleepAssertionControl()
        self.sleep = sleep
        let battery = BatteryService(settings: settings)
        self.battery = battery
        battery.batteryState = makeBatteryState(percentage: 80)
        manager = ChargingManager(settings: settings, helper: helper, battery: battery,
                                  sleepAssertion: sleep, nativeChargeLimitControl: native,
                                  smcChargingAPIDetector: { smcAPI })
    }

    func cleanUp() { settings.defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class NativeLimitMock: NativeChargeLimitControl {
    var snapshot: NativeChargeLimitSnapshot
    var readError: Error?
    var writeError: Error?
    var honorsWrites = true
    var stateAfterWrite: NativeChargeLimitSnapshot?
    var replyOverride: NativeChargeLimitSnapshot?
    var failedReadNumbers: Set<Int> = []
    private(set) var readCount = 0
    private(set) var writes: [Int] = []
    var optimized: Bool?
    var honorsOptimizedWrites = true
    private(set) var optimizedWrites: [Bool] = []

    init(snapshot: NativeChargeLimitSnapshot) { self.snapshot = snapshot }

    func readState() throws -> NativeChargeLimitSnapshot {
        readCount += 1
        if failedReadNumbers.contains(readCount) { throw NativeChargeLimitError.unavailable }
        if let readError { throw readError }
        return snapshot
    }

    func setLimit(_ limit: Int) throws -> NativeChargeLimitSnapshot {
        writes.append(limit)
        if let stateAfterWrite { snapshot = stateAfterWrite }
        else if honorsWrites {
            snapshot = NativeChargeLimitSnapshot(availableLimits: snapshot.availableLimits,
                                                 limit: limit == 100 ? snapshot.limit : limit,
                                                 enabled: limit != 100)
        }
        if let writeError { throw writeError }
        return replyOverride ?? snapshot
    }

    func readOptimizedCharging() throws -> Bool {
        guard let optimized else { throw NativeChargeLimitError.optimizedUnavailable }
        return optimized
    }

    func setOptimizedCharging(_ enabled: Bool) throws -> Bool {
        optimizedWrites.append(enabled)
        if honorsOptimizedWrites { optimized = enabled }
        return enabled
    }
}

/// Includes synchronous termination reset, which the original shared mock omits.
private final class NativeSMCRecordingControl: ChargingControl, @unchecked Sendable {
    enum Call: Equatable { case enable, inhibit, discharge, reset, led, terminationReset }
    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    var calls: [Call] { lock.withLock { recordedCalls } }

    private func record(_ call: Call, completion: (@Sendable (Bool, String?) -> Void)?) {
        lock.withLock { recordedCalls.append(call) }
        completion?(true, nil)
    }
    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)?) { record(.enable, completion: completion) }
    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)?) { record(.inhibit, completion: completion) }
    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)?) { record(.discharge, completion: completion) }
    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)?) { record(.reset, completion: completion) }
    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)?) { record(.led, completion: completion) }
    func resetToDefaultsSync(timeout: TimeInterval) { record(.terminationReset, completion: nil) }
}

private final class NativeDeferredSMCControl: ChargingControl, @unchecked Sendable {
    enum Call: Equatable { case enable, inhibit, discharge, reset, led, terminationReset }
    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var replies: [(@Sendable (Bool, String?) -> Void)?] = []
    var calls: [Call] { lock.withLock { recordedCalls } }

    private func record(_ call: Call, completion: (@Sendable (Bool, String?) -> Void)?) {
        lock.withLock {
            recordedCalls.append(call)
            replies.append(completion)
        }
    }
    func reply(_ index: Int, success: Bool) {
        let callback = lock.withLock { replies[index] }
        callback?(success, success ? nil : "old SMC operation failed")
    }
    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)?) { record(.enable, completion: completion) }
    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)?) { record(.inhibit, completion: completion) }
    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)?) { record(.discharge, completion: completion) }
    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)?) { record(.reset, completion: completion) }
    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)?) { record(.led, completion: completion) }
    func resetToDefaultsSync(timeout: TimeInterval) { record(.terminationReset, completion: nil) }
}
