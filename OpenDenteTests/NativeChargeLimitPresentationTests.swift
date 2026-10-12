import XCTest
@testable import OpenDente

@MainActor
final class NativeChargeLimitPresentationTests: XCTestCase {
    private func presentation(requested: Int = 80, effective: Int? = 80,
                              available: [Int] = [80, 85, 90, 95, 100],
                              error: String? = nil, temporaryOverride: Bool = false) -> NativeChargeLimitPresentation {
        NativeChargeLimitPresentation(requestedLimit: requested, effectiveLimit: effective,
                                      availableLimits: available, error: error, isTemporaryOverride: temporaryOverride)
    }

    func testNativeChoicesComeFromReportedSupportedValues() {
        let result = presentation(available: [100, 90, 90, 60, 81, 105])
        XCTAssertEqual(result.choices, [81, 90, 100])
        XCTAssertEqual(result.selection, 81)
    }

    func testNativeChoicesDoNotInventCapabilitiesWhenUnavailable() {
        XCTAssertTrue(presentation(available: []).choices.isEmpty)
    }

    func testFailedRequestShowsEffectiveLimitAndErrorInsteadOfRequestedSuccess() {
        let result = presentation(requested: 100, effective: 80, error: "Write rejected")
        XCTAssertEqual(result.limitLabel, "Native limit: 80%")
        XCTAssertEqual(result.statusLabel(observedMode: .paused), "Native control error")
        XCTAssertTrue(result.hasUnappliedRequest)
        XCTAssertTrue(result.hasWarning)
        XCTAssertEqual(result.error, "Write rejected")
    }

    func testMissingReadbackDoesNotDisplaySavedLimitAsEffective() {
        let result = presentation(effective: nil)
        XCTAssertEqual(result.limitLabel, "Native limit: Unavailable")
        XCTAssertEqual(result.statusLabel(observedMode: .paused), "Native limit unavailable")
        XCTAssertTrue(result.hasWarning)
    }

    func testUnexpectedDifferentLimitDoesNotPromiseAnAsyncOperation() {
        let result = presentation(requested: 100, effective: 80)
        XCTAssertEqual(result.statusLabel(observedMode: .paused), "Requested limit not active")
        XCTAssertTrue(result.hasWarning)
    }

    func testConfirmedNativeLimitDisplaysObservedChargingEvenAtLimit() {
        let result = presentation()
        XCTAssertEqual(result.statusLabel(observedMode: .charging), ChargingMode.charging.displayName)
        XCTAssertEqual(result.statusLabel(observedMode: .paused), ChargingMode.paused.displayName)
        XCTAssertFalse(result.hasUnappliedRequest)
        XCTAssertFalse(result.hasWarning)
    }

    func testConfirmedTemporaryFullChargeShowsUsualAndEffectiveLimitsWithoutWarning() {
        let result = presentation(requested: 80, effective: 100, temporaryOverride: true)
        XCTAssertEqual(result.selection, 80)
        XCTAssertEqual(result.effectiveLimitLabel, "100%")
        XCTAssertEqual(result.limitLabel, "Usual: 80% · Temporary: 100%")
        XCTAssertEqual(result.statusLabel(observedMode: .charging), "Temporary Full Charge")
        XCTAssertTrue(result.hasConfirmedTemporaryFullCharge)
        XCTAssertFalse(result.hasUnappliedRequest)
        XCTAssertFalse(result.hasWarning)
    }

    func testFullChargeMismatchWithoutConfirmedOverrideKeepsWarning() {
        let result = presentation(requested: 80, effective: 100)
        XCTAssertFalse(result.hasConfirmedTemporaryFullCharge)
        XCTAssertEqual(result.limitLabel, "Native limit: 100%")
        XCTAssertEqual(result.statusLabel(observedMode: .charging), "Requested limit not active")
        XCTAssertTrue(result.hasUnappliedRequest)
        XCTAssertTrue(result.hasWarning)
    }

    func testTemporaryReadbackDoesNotHideAnActualControlError() {
        let result = presentation(requested: 80, effective: 100, error: "Read failed", temporaryOverride: true)
        XCTAssertFalse(result.hasConfirmedTemporaryFullCharge)
        XCTAssertEqual(result.statusLabel(observedMode: .charging), "Native control error")
        XCTAssertTrue(result.hasUnappliedRequest)
        XCTAssertTrue(result.hasWarning)
    }

    func testTemporaryFlagCannotSubstituteForMissingReadback() {
        let result = presentation(effective: nil, temporaryOverride: true)
        XCTAssertFalse(result.hasConfirmedTemporaryFullCharge)
        XCTAssertEqual(result.limitLabel, "Native limit: Unavailable")
        XCTAssertEqual(result.statusLabel(observedMode: .charging), "Native limit unavailable")
        XCTAssertTrue(result.hasWarning)
    }

    func testTemporaryFlagWithNonFullEffectiveLimitKeepsMismatchWarning() {
        let result = presentation(requested: 80, effective: 95, temporaryOverride: true)
        XCTAssertFalse(result.hasConfirmedTemporaryFullCharge)
        XCTAssertEqual(result.statusLabel(observedMode: .charging), "Requested limit not active")
        XCTAssertTrue(result.hasWarning)
    }

    func testUnsupportedSavedLimitUsesReportedEffectiveChoice() {
        let result = presentation(requested: 60, effective: 85, error: "Unsupported limit")
        XCTAssertEqual(result.selection, 85)
        XCTAssertEqual(result.limitLabel, "Native limit: 85%")
        XCTAssertTrue(result.hasUnappliedRequest)
    }

    func testExternalSystemChangeIsDisplayedOnceAdopted() {
        let result = presentation(requested: 95, effective: 95)
        XCTAssertEqual(result.selection, 95)
        XCTAssertEqual(result.limitLabel, "Native limit: 95%")
        XCTAssertFalse(result.hasWarning)
    }
    func testNativeLimitNotificationRequiresObservedPauseAtConfirmedLimit() {
        XCTAssertTrue(AppDelegate.canNotifyNativeLimitReached(
            state: makeBatteryState(percentage: 80, isCharging: false),
            requestedLimit: 80, effectiveLimit: 80, error: nil
        ))
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: makeBatteryState(percentage: 80, isCharging: true),
            requestedLimit: 80, effectiveLimit: 80, error: nil
        ))
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: makeBatteryState(percentage: 75, isCharging: false),
            requestedLimit: 80, effectiveLimit: 80, error: nil
        ))
    }

    func testNativeLimitNotificationRejectsMissingFailedOrDifferentReadback() {
        let state = makeBatteryState(percentage: 80, isCharging: false)
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: state, requestedLimit: 80, effectiveLimit: nil, error: nil
        ))
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: state, requestedLimit: 100, effectiveLimit: 80, error: nil
        ))
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: state, requestedLimit: 80, effectiveLimit: 80, error: "Read failed"
        ))
    }

    func testNativeLimitNotificationRejectsUnpluggedOrInvalidBattery() {
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: makeBatteryState(percentage: 80, isCharging: false, isPluggedIn: false),
            requestedLimit: 80, effectiveLimit: 80, error: nil
        ))
        var state = makeBatteryState(percentage: 80, isCharging: false)
        state.hasValidBatteryReading = false
        XCTAssertFalse(AppDelegate.canNotifyNativeLimitReached(
            state: state, requestedLimit: 80, effectiveLimit: 80, error: nil
        ))
    }

}
