import Foundation
import Testing
import XCTest
@testable import OpenDente

@MainActor
private final class FakeNativeChargeLimitTransport: NativeChargeLimitTransport {
    enum Failure: Error, Equatable { case read, write }

    var replies: [[String: Any]]
    var readFailureAt: Int?
    var writeFailure = false
    private(set) var reads = 0
    private(set) var appliedLimits: [Int] = []
    private(set) var disables = 0

    init(_ replies: [[String: Any]]) { self.replies = replies }

    func readRawState() throws -> [String: Any] {
        reads += 1
        if readFailureAt == reads { throw Failure.read }
        guard !replies.isEmpty else { throw Failure.read }
        return replies[min(reads - 1, replies.count - 1)]
    }

    func applyLimit(_ limit: Int) throws {
        appliedLimits.append(limit)
        if writeFailure { throw Failure.write }
    }

    func disable() throws {
        disables += 1
        if writeFailure { throw Failure.write }
    }
}

@MainActor
struct NativeChargeLimitServiceTests {
    private func raw(limit: Int = 80, enabled: Int = 1, limits: [Int] = [80, 85, 90, 95, 100]) -> [String: Any] {
        ["supported": true, "availableLimits": limits, "limit": limit, "enabled": enabled]
    }

    @Test
    func sortsActualAvailableLimitsWithoutInventingSteps() throws {
        let transport = FakeNativeChargeLimitTransport([raw(limit: 81, limits: [100, 90, 81, 80])])
        let state = try PowerUINativeChargeLimitControl(transport: transport).readState()
        #expect(state == NativeChargeLimitSnapshot(availableLimits: [80, 81, 90, 100], limit: 81, enabled: true))
        #expect(state.effectiveLimit == 81)
        #expect(transport.appliedLimits.isEmpty && transport.disables == 0)
    }

    @Test(arguments: [0, 79, 85, 100])
    func disabledPolicyPreservesStoredValueAndMeans100(stored: Int) throws {
        let transport = FakeNativeChargeLimitTransport([raw(limit: stored, enabled: 0)])
        let state = try PowerUINativeChargeLimitControl(transport: transport).readState()
        #expect(state.limit == stored)
        #expect(!state.enabled && state.effectiveLimit == 100)
    }

    @Test
    func unsupportedHardwareCannotWrite() {
        let transport = FakeNativeChargeLimitTransport([["supported": false]])
        #expect(throws: NativeChargeLimitError.unavailable) {
            try PowerUINativeChargeLimitControl(transport: transport).setLimit(85)
        }
        #expect(transport.appliedLimits.isEmpty && transport.disables == 0)
    }

    @Test(arguments: [0, 79, 101])
    func invalidRequestDoesNotEvenRead(limit: Int) {
        let transport = FakeNativeChargeLimitTransport([raw()])
        #expect(throws: NativeChargeLimitError.unsupportedLimit(limit)) {
            try PowerUINativeChargeLimitControl(transport: transport).setLimit(limit)
        }
        #expect(transport.reads == 0 && transport.appliedLimits.isEmpty && transport.disables == 0)
    }

    @Test
    func unsupportedInRangeRequestDoesNotWrite() {
        let transport = FakeNativeChargeLimitTransport([raw()])
        #expect(throws: NativeChargeLimitError.unsupportedLimit(83)) {
            try PowerUINativeChargeLimitControl(transport: transport).setLimit(83)
        }
        #expect(transport.reads == 1 && transport.appliedLimits.isEmpty && transport.disables == 0)
    }

    @Test
    func appliesAndVerifiesSupportedLimit() throws {
        let transport = FakeNativeChargeLimitTransport([raw(), raw(limit: 85)])
        let state = try PowerUINativeChargeLimitControl(transport: transport).setLimit(85)
        #expect(state.enabled && state.effectiveLimit == 85)
        #expect(transport.appliedLimits == [85] && transport.disables == 0 && transport.reads == 2)
    }

    @Test
    func hundredUsesDisableAndVerifiesItsResult() throws {
        let transport = FakeNativeChargeLimitTransport([raw(limit: 85), raw(limit: 85, enabled: 0)])
        let state = try PowerUINativeChargeLimitControl(transport: transport).setLimit(100)
        #expect(!state.enabled && state.effectiveLimit == 100)
        #expect(transport.appliedLimits.isEmpty && transport.disables == 1 && transport.reads == 2)
    }

    @Test
    func alreadyAppliedPoliciesDoNotWriteAgain() throws {
        let enabled = FakeNativeChargeLimitTransport([raw(limit: 85)])
        _ = try PowerUINativeChargeLimitControl(transport: enabled).setLimit(85)
        #expect(enabled.reads == 1 && enabled.appliedLimits.isEmpty && enabled.disables == 0)
        let disabled = FakeNativeChargeLimitTransport([raw(limit: 0, enabled: 0)])
        _ = try PowerUINativeChargeLimitControl(transport: disabled).setLimit(100)
        #expect(disabled.reads == 1 && disabled.appliedLimits.isEmpty && disabled.disables == 0)
    }

    @Test
    func changedStoredValueWithoutEnabledPolicyIsNotSuccess() {
        let transport = FakeNativeChargeLimitTransport([raw(), raw(limit: 85, enabled: 0)])
        #expect(throws: NativeChargeLimitError.verificationFailed(requested: 85, actual: 100, enabled: false)) {
            try PowerUINativeChargeLimitControl(transport: transport).setLimit(85)
        }
        #expect(transport.appliedLimits == [85] && transport.reads == 2)
    }

    @Test
    func unchangedReadbackIsNotSuccess() {
        let transport = FakeNativeChargeLimitTransport([raw()])
        #expect(throws: NativeChargeLimitError.verificationFailed(requested: 85, actual: 80, enabled: true)) {
            try PowerUINativeChargeLimitControl(transport: transport).setLimit(85)
        }
        #expect(transport.appliedLimits == [85] && transport.reads == 2)
    }

    @Test
    func hundredMustActuallyDisablePolicy() {
        let transport = FakeNativeChargeLimitTransport([raw(), raw(limit: 100)])
        #expect(throws: NativeChargeLimitError.verificationFailed(requested: 100, actual: 100, enabled: true)) {
            try PowerUINativeChargeLimitControl(transport: transport).setLimit(100)
        }
        #expect(transport.disables == 1 && transport.reads == 2)
    }

    @Test
    func transportErrorsPropagateAndNeverProduceSuccess() {
        let read = FakeNativeChargeLimitTransport([raw()])
        read.readFailureAt = 1
        #expect(throws: FakeNativeChargeLimitTransport.Failure.read) {
            try PowerUINativeChargeLimitControl(transport: read).setLimit(85)
        }
        #expect(read.appliedLimits.isEmpty)
        let write = FakeNativeChargeLimitTransport([raw()])
        write.writeFailure = true
        #expect(throws: FakeNativeChargeLimitTransport.Failure.write) {
            try PowerUINativeChargeLimitControl(transport: write).setLimit(85)
        }
        #expect(write.reads == 1)
        let readback = FakeNativeChargeLimitTransport([raw()])
        readback.readFailureAt = 2
        #expect(throws: FakeNativeChargeLimitTransport.Failure.read) {
            try PowerUINativeChargeLimitControl(transport: readback).setLimit(85)
        }
        #expect(readback.appliedLimits == [85] && readback.reads == 2)
    }

    @Test
    func malformedPrivateRepliesFailBeforeWriting() {
        var cases: [[String: Any]] = [[:]]
        let fields: [(String, Any)] = [
            ("supported", 1), ("supported", "true"),
            ("availableLimits", [] as [Int]), ("availableLimits", [80, 85, 85, 100]),
            ("availableLimits", [80, 85, 90]), ("availableLimits", [79, 80, 100]),
            ("availableLimits", [80, 101, 100]), ("availableLimits", [80, 85.5, 100]),
            ("availableLimits", [true, 80, 100] as [Any]),
            ("availableLimits", [Double.nan, 80, 100]), ("availableLimits", [Double.infinity, 80, 100]),
            ("limit", true), ("limit", 85.5), ("limit", Double.nan),
            ("limit", 101), ("limit", -1), ("limit", "80"), ("limit", 83),
            ("enabled", 2), ("enabled", -1), ("enabled", "1"), ("enabled", 0.5)
        ]
        for (field, value) in fields {
            var malformed = raw()
            malformed[field] = value
            cases.append(malformed)
        }
        for reply in cases {
            let transport = FakeNativeChargeLimitTransport([reply])
            #expect(throws: NativeChargeLimitError.self) {
                try PowerUINativeChargeLimitControl(transport: transport).setLimit(85)
            }
            #expect(transport.appliedLimits.isEmpty && transport.disables == 0)
        }
    }

    @Test
    func productionBridgeRejectsBothMutatorsInTestProcess() throws {
        // This is the same first condition as the bridge's write guard. Abort
        // before either call if the runner has failed to load XCTest.
        try #require(NSClassFromString("XCTestCase") != nil)
        let bridge = ODNativeChargeLimitBridge()
        var error: NSError?
        #expect(!bridge.applyLimit(85, error: &error))
        #expect(error?.domain == "com.opendente.NativeChargeLimitBridge" && error?.code == 6)
        error = nil
        #expect(!bridge.disable(&error))
        #expect(error?.domain == "com.opendente.NativeChargeLimitBridge" && error?.code == 6)
    }

    @Test func absentNativeSupportEntryPointIsKnownUnsupportedWithoutCallingPowerUI() {
        let bridge = ODNativeChargeLimitBridge()
        bridge.setValue(NSObject(), forKey: "client")
        var error: NSError?
        let state = bridge.readState(&error)
        #expect((state?["supported"] as? NSNumber)?.boolValue == false)
        #expect(error == nil)
        #expect(!bridge.supportsTemporaryFullCharge(&error))
        #expect(error == nil)
    }

    @Test func explicitlyUnsupportedNativeHardwareNeedsNoMutationOrChoiceSelectors() {
        let bridge = ODNativeChargeLimitBridge()
        bridge.setValue(NativeUnsupportedClient(), forKey: "client")
        var error: NSError?
        let state = bridge.readState(&error)
        #expect((state?["supported"] as? NSNumber)?.boolValue == false)
        #expect(error == nil)
    }

    @Test func changedSupportABIAndMissingContractsOnSupportedHardwareStayErrors() {
        let bridge = ODNativeChargeLimitBridge()
        bridge.setValue(NativeChangedSupportABIClient(), forKey: "client")
        var error: NSError?
        #expect(bridge.readState(&error) == nil)
        #expect(error?.code == 2)
        bridge.setValue(NativeSupportedClientWithoutLimitMethods(), forKey: "client")
        error = nil
        #expect(bridge.readState(&error) == nil)
        #expect(error?.code == 2)
    }
}

private final class NativeUnsupportedClient: NSObject {
    @objc func isMCLSupported() -> Bool { false }
}

private final class NativeChangedSupportABIClient: NSObject {
    @objc func isMCLSupported() -> Int { 0 }
}

private final class NativeSupportedClientWithoutLimitMethods: NSObject {
    @objc func isMCLSupported() -> Bool { true }
}
