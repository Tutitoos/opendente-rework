import Foundation
import Testing
import XCTest
@testable import OpenDente

@Suite("Native optimized and temporary charging")
@MainActor
struct NativeOptimizedChargingTests {
    @Test(arguments: [0, 1, 2, 3])
    func nativeOBCRawStatesKeepConfigurationSeparateFromOverride(state: Int) throws {
        let transport = NativePolicyTransportMock()
        transport.optimizedState = state
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let snapshot = try control.readOptimizedChargingState()
        #expect(snapshot.state == state)
        #expect(snapshot.enabled == (state != 0))
        #expect(snapshot.temporarilyOverridden == (state >= 2))
        #expect(transport.limitWrites.isEmpty && transport.optimizedWrites.isEmpty)
    }

    @Test func temporaryMCLRaw3IsDistinctFromExternalPersistent100Raw0() throws {
        let transport = NativePolicyTransportMock()
        transport.limitState = 3
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let temporary = try control.readState()
        #expect(temporary.isTemporaryOverride && temporary.effectiveLimit == 100)
        transport.limitState = 0
        let permanent = try control.readState()
        #expect(!permanent.isTemporaryOverride && permanent.effectiveLimit == 100)
        #expect(temporary != permanent)
    }

    @Test func explicit100DisablesTemporaryMCLRatherThanTreatingItAsAlreadySaved() throws {
        let transport = NativePolicyTransportMock()
        transport.limitState = 3
        _ = try PowerUINativeChargeLimitControl(transport: transport).setLimit(100)
        #expect(transport.disables == 1)
        #expect(transport.limitState == 0)
    }

    @Test func explicitOptimizedOnClearsTemporaryOverrideAndChecksReadback() throws {
        let transport = NativePolicyTransportMock()
        transport.optimizedState = 2
        _ = try PowerUINativeChargeLimitControl(transport: transport).setOptimizedCharging(true)
        #expect(transport.optimizedWrites == [true])
        #expect(transport.optimizedState == 1)
        #expect(transport.limitWrites.isEmpty)
    }

    @Test func optimizedAndLimitWritesNeverChangeTheOtherFeature() throws {
        let transport = NativePolicyTransportMock()
        let control = PowerUINativeChargeLimitControl(transport: transport)
        _ = try control.setOptimizedCharging(false)
        #expect(transport.limit == 80 && transport.limitState == 1)
        _ = try control.setLimit(90)
        #expect(transport.optimizedState == 0)
        #expect(transport.optimizedWrites == [false])
    }

    @Test func optimizedWriteFailureAndWrongReadbackAreFailures() {
        let transport = NativePolicyTransportMock()
        transport.honorOptimizedWrites = false
        let control = PowerUINativeChargeLimitControl(transport: transport)
        #expect(throws: NativeChargeLimitError.optimizedVerificationFailed(requested: false, actual: true)) {
            try control.setOptimizedCharging(false)
        }
        #expect(transport.optimizedState == 1)
        transport.writeError = NativeChargeLimitError.optimizedUnavailable
        #expect(throws: NativeChargeLimitError.optimizedUnavailable) { try control.setOptimizedCharging(false) }
    }

    @Test(arguments: [-1, 4, 7])
    func unknownOBCStatesCannotBecomeAControl(state: Int) {
        let transport = NativePolicyTransportMock()
        transport.optimizedState = state
        #expect(throws: NativeChargeLimitError.self) {
            try PowerUINativeChargeLimitControl(transport: transport).setOptimizedCharging(false)
        }
        #expect(transport.optimizedWrites.isEmpty)
    }

    @Test func temporaryOperationDoesNotPersist100AndRestoresBothPolicies() throws {
        let transport = NativePolicyTransportMock()
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let previous = try control.readFullChargePolicy()
        let temporary = try control.beginTemporaryFullCharge()
        #expect(temporary.chargeLimit.nativeFeatureState == 3)
        #expect(temporary.optimizedChargingState == 2)
        #expect(transport.disables == 0 && transport.limitWrites.isEmpty)
        let restored = try control.restoreAfterTemporaryFullCharge(previous)
        #expect(restored.hasSamePolicy(as: previous))
        #expect(transport.limitWrites == [80] && transport.optimizedWrites == [true])
    }

    @Test func temporarySuccessReplyWithout100ReadbackCannotReportSuccess() {
        let transport = NativePolicyTransportMock()
        transport.honorTemporaryWrites = false
        #expect(throws: NativeChargeLimitError.self) {
            try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        }
    }

    @Test(arguments: [true, false])
    func admittedOBCOverrideIsVerifiedBeforeMCL(engaged: Bool) throws {
        let transport = NativePolicyTransportMock()
        transport.engaged = engaged
        transport.overrideAllowed = true
        let result = try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        #expect(transport.temporaryWrites == ["obc", "mcl"])
        #expect(result.optimizedChargingState == 2 && result.chargeLimit.isTemporaryOverride)
    }

    @Test func enabledButUnengagedInadmissibleOBCIsPreservedDuringTemporaryMCL() throws {
        let transport = NativePolicyTransportMock()
        transport.engaged = false
        transport.overrideAllowed = false
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let previous = try control.readFullChargePolicy()
        let result = try control.beginTemporaryFullCharge(expectedPolicy: previous)
        #expect(result.optimizedChargingState == 1)
        #expect(transport.temporaryWrites == ["mcl"])
        _ = try control.restoreAfterTemporaryFullCharge(previous)
        #expect(transport.optimizedWrites.isEmpty && transport.limitWrites == [80])
    }

    @Test func engagedWithoutOverridePermissionFailsBeforeAnyWrite() {
        let transport = NativePolicyTransportMock()
        transport.engaged = true
        transport.overrideAllowed = false
        #expect(throws: NativeChargeLimitError.temporaryUnavailable) {
            try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        }
        #expect(transport.temporaryWrites.isEmpty)
    }

    @Test func falseEngagementWithNSErrorIsNotAUsableFalse() {
        let transport = NativePolicyTransportMock()
        transport.engaged = false
        let failure = NSError(domain: "PowerUISmartChargingErrorDomain", code: 2)
        transport.engagementError = failure
        #expect(throws: failure) {
            try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        }
        #expect(transport.temporaryWrites.isEmpty)
    }

    @Test func invalidEngagementReplyFailsBeforeAnyWrite() {
        let transport = NativePolicyTransportMock()
        transport.rawEngagement = ["supported": true, "engaged": NSNumber(value: 1), "overrideAllowed": true]
        #expect(throws: NativeChargeLimitError.self) {
            try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        }
        #expect(transport.temporaryWrites.isEmpty)
    }

    @Test func rejectedOBCError2IsNeverIgnoredOrFollowedByMCL() {
        let transport = NativePolicyTransportMock()
        let failure = NSError(domain: "PowerUISmartChargingErrorDomain", code: 2)
        transport.temporaryOBCError = failure
        #expect(throws: failure) {
            try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        }
        #expect(transport.temporaryWrites == ["obc"])
        #expect(transport.limitState == 1 && transport.optimizedState == 1)
    }

    @Test func successfulOBCReplyWithoutState2CannotTouchMCL() {
        let transport = NativePolicyTransportMock()
        transport.honorOptimizedTemporaryWrites = false
        #expect(throws: NativeChargeLimitError.self) {
            try PowerUINativeChargeLimitControl(transport: transport).beginTemporaryFullCharge()
        }
        #expect(transport.temporaryWrites == ["obc"])
        #expect(transport.limitState == 1)
    }

    @Test func partialOBC2ThenMCLFailureRestoresOnlyOBC() throws {
        let transport = NativePolicyTransportMock()
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let previous = try control.readFullChargePolicy()
        let failure = NSError(domain: "PowerUISmartChargingErrorDomain", code: 2)
        transport.temporaryMCLError = failure
        #expect(throws: failure) { try control.beginTemporaryFullCharge(expectedPolicy: previous) }
        #expect(transport.optimizedState == 2 && transport.limitState == 1)
        _ = try control.restoreAfterTemporaryFullCharge(previous)
        #expect(transport.optimizedWrites == [true] && transport.limitWrites.isEmpty)
    }

    @Test func persistedPolicyMismatchAbortsBeforeOverride() throws {
        let transport = NativePolicyTransportMock()
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let journalPolicy = try control.readFullChargePolicy()
        transport.limit = 85
        #expect(throws: NativeChargeLimitError.self) { try control.beginTemporaryFullCharge(expectedPolicy: journalPolicy) }
        #expect(transport.temporaryWrites.isEmpty && transport.limit == 85)
    }

    @Test func externalLimitChangedBetweenOBCAndMCLIsPreservedOnRecovery() throws {
        let transport = NativePolicyTransportMock()
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let previous = try control.readFullChargePolicy()
        transport.afterTemporaryOBC = { transport.limit = 85 }
        #expect(throws: NativeChargeLimitError.self) { try control.beginTemporaryFullCharge(expectedPolicy: previous) }
        let external = try control.readFullChargePolicy()
        let intended = NativeChargingPolicySnapshot(chargeLimit: external.chargeLimit,
                                                    optimizedChargingEnabled: true, optimizedChargingState: 1)
        _ = try control.restoreAfterTemporaryFullCharge(intended)
        #expect(transport.limit == 85 && transport.limitWrites.isEmpty)
        #expect(transport.optimizedWrites == [true])
    }

    @Test func laterOBCRetentionIsOperationalRatherThanAChangedPolicy() throws {
        let transport = NativePolicyTransportMock()
        transport.engaged = false
        transport.overrideAllowed = false
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let temporary = try control.beginTemporaryFullCharge()
        #expect(try control.canContinueTemporaryFullCharge())
        transport.engaged = true
        #expect(!(try control.canContinueTemporaryFullCharge()))
        #expect(try control.readFullChargePolicy().hasSamePolicy(as: temporary))
        #expect(transport.temporaryWrites == ["mcl"])
    }

    @Test func hotfixErrorDetailsTranslateWhileSourceEventsStayStable() throws {
        let bundle = Bundle(for: LanguageManager.self)
        let cases: [(Error, String, String)] = [
            (NativeChargeLimitError.temporaryVerificationFailed("the charging policy changed before temporary charging"),
             "the charging policy changed before temporary charging", "la política de carga cambió antes de iniciar la carga temporal"),
            (NativeChargeLimitError.invalidState("optimized charging retention is not a Boolean"),
             "optimized charging retention is not a Boolean", "el estado de retención de la carga optimizada no es un valor booleano"),
            (NativeChargeLimitError.invalidState("optimized charging override permission is not a Boolean"),
             "optimized charging override permission is not a Boolean", "el permiso de excepción de la carga optimizada no es un valor booleano"),
            (NSError(domain: "com.opendente.NativeChargeLimitBridge", code: 3,
                     userInfo: [NSLocalizedDescriptionKey: "macOS did not return optimized charging retention."]),
             "macOS did not return optimized charging retention.", "macOS no ha devuelto el estado de retención de la carga optimizada.")
        ]
        for (error, english, spanish) in cases {
            let failure = ChargingPolicyFailure(error: error)
            #expect(L10n.localized(english, language: .english, bundle: bundle) == english)
            #expect(L10n.localized(english, language: .spanish, bundle: bundle) == spanish)
            #expect(ChargingPolicyFailure(error: error) == failure)
            #expect(error.localizedDescription.contains(english))
        }
    }

    @Test func restoringOnlyOurOBCLeavesAnExternalTemporaryMCLUntouched() throws {
        let transport = NativePolicyTransportMock()
        transport.limit = 95
        transport.limitState = 3
        transport.optimizedState = 2
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let observed = try control.readFullChargePolicy()
        let intended = NativeChargingPolicySnapshot(chargeLimit: observed.chargeLimit,
                                                    optimizedChargingEnabled: true, optimizedChargingState: 1)
        let restored = try control.restoreAfterTemporaryFullCharge(intended)
        #expect(restored.hasSamePolicy(as: intended))
        #expect(restored.chargeLimit.isTemporaryOverride)
        #expect(transport.limit == 95 && transport.limitState == 3)
        #expect(transport.disables == 0 && transport.limitWrites.isEmpty)
        #expect(transport.optimizedWrites == [true])
    }

    @Test func restorationDoesNotRewriteAlreadyCanonicalIndependentPolicies() throws {
        let transport = NativePolicyTransportMock()
        transport.limit = 90
        transport.optimizedState = 0
        let control = PowerUINativeChargeLimitControl(transport: transport)
        let actual = try control.readFullChargePolicy()
        _ = try control.restoreAfterTemporaryFullCharge(actual)
        #expect(transport.disables == 0 && transport.limitWrites.isEmpty && transport.optimizedWrites.isEmpty)
    }

    @Test func testProcessesBlockEveryProductionMutatorBeforeContactingPowerUI() throws {
        try #require(NSClassFromString("XCTestCase") != nil)
        let bridge = ODNativeChargeLimitBridge()
        var error: NSError?
        #expect(!bridge.setOptimizedCharging(false, error: &error))
        #expect(error?.code == 6)
        error = nil
        #expect(!bridge.temporarilyOverrideOptimizedCharging(&error))
        #expect(error?.code == 6)
        error = nil
        #expect(!bridge.temporarilyDisableChargeLimit(80, error: &error))
        #expect(error?.code == 6)
        error = nil
        #expect(!bridge.applyLimit(85, error: &error))
        #expect(error?.code == 6)
        error = nil
        #expect(!bridge.disable(&error))
        #expect(error?.code == 6)
    }
}

@MainActor
private final class NativePolicyTransportMock: NativeChargeLimitTransport {
    var limit = 80
    var limitState = 1
    var optimizedState = 1
    var honorOptimizedWrites = true
    var honorTemporaryWrites = true
    var honorOptimizedTemporaryWrites = true
    var engaged = true
    var overrideAllowed = true
    var engagementError: Error?
    var rawEngagement: [String: Any]?
    var temporaryOBCError: Error?
    var temporaryMCLError: Error?
    var afterTemporaryOBC: (() -> Void)?
    var writeError: Error?
    private(set) var limitWrites: [Int] = []
    private(set) var disables = 0
    private(set) var optimizedWrites: [Bool] = []
    private(set) var temporaryWrites: [String] = []

    func readRawState() throws -> [String: Any] {
        ["supported": true, "availableLimits": [80, 85, 90, 95, 100], "limit": limitState == 3 ? 100 : limit, "enabled": limitState]
    }
    func applyLimit(_ limit: Int) throws {
        if let writeError { throw writeError }
        limitWrites.append(limit)
        self.limit = limit
        limitState = 1
    }
    func disable() throws {
        if let writeError { throw writeError }
        disables += 1
        limitState = 0
    }
    func readRawOptimizedCharging() throws -> [String: Any] { ["supported": true, "enabled": optimizedState] }
    func applyOptimizedCharging(_ enabled: Bool) throws {
        if let writeError { throw writeError }
        optimizedWrites.append(enabled)
        if honorOptimizedWrites { optimizedState = enabled ? 1 : 0 }
    }
    func temporaryFullChargeAvailable() throws -> Bool { true }
    func readRawOptimizedChargingEngagement() throws -> [String: Any] {
        if let engagementError { throw engagementError }
        return rawEngagement ?? ["supported": true, "engaged": engaged, "overrideAllowed": overrideAllowed]
    }
    func temporarilyOverrideOptimizedCharging() throws {
        temporaryWrites.append("obc")
        if let temporaryOBCError { throw temporaryOBCError }
        if let writeError { throw writeError }
        if honorOptimizedTemporaryWrites { optimizedState = 2 }
        afterTemporaryOBC?()
    }
    func temporarilyDisableChargeLimit(expectedLimit: Int) throws {
        guard limitState == 1, limit == expectedLimit else { throw NativeChargeLimitError.temporaryUnavailable }
        temporaryWrites.append("mcl")
        if let temporaryMCLError { throw temporaryMCLError }
        if let writeError { throw writeError }
        if honorTemporaryWrites { limitState = 3 }
    }
}
