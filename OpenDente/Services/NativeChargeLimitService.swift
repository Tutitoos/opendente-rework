import Foundation
import CoreFoundation

struct NativeChargeLimitSnapshot: Sendable, Equatable, Codable {
    let availableLimits: [Int]
    let limit: Int
    let enabled: Bool
    /// PowerUI returns0 (disabled),1 (enabled),3 (temporarily disabled).
    /// Its API status3 differs from internal feature state2 in the daemon.
    let nativeFeatureState: Int

    init(availableLimits: [Int], limit: Int, enabled: Bool, nativeFeatureState: Int? = nil) {
        self.availableLimits = availableLimits
        self.limit = limit
        self.enabled = enabled
        self.nativeFeatureState = nativeFeatureState ?? (enabled ? 1 : 0)
    }

    var effectiveLimit: Int { enabled ? limit : 100 }
    var isTemporaryOverride: Bool { nativeFeatureState == 3 }
}

struct NativeChargingPolicySnapshot: Sendable, Equatable, Codable {
    let chargeLimit: NativeChargeLimitSnapshot
    let optimizedChargingEnabled: Bool?
    let optimizedChargingState: Int?

    init(chargeLimit: NativeChargeLimitSnapshot, optimizedChargingEnabled: Bool?, optimizedChargingState: Int? = nil) {
        self.chargeLimit = chargeLimit
        self.optimizedChargingEnabled = optimizedChargingEnabled
        self.optimizedChargingState = optimizedChargingState ?? optimizedChargingEnabled.map { $0 ? 1 : 0 }
    }

    /// Disabled MCL may retain an old stored limit; compare effective policy.
    func hasSamePolicy(as other: Self) -> Bool {
        chargeLimit.effectiveLimit == other.chargeLimit.effectiveLimit &&
        chargeLimit.nativeFeatureState == other.chargeLimit.nativeFeatureState &&
        optimizedChargingState == other.optimizedChargingState
    }
}

struct NativeOptimizedChargingSnapshot: Sendable, Equatable {
    ///0 disabled,1 enabled,2 charging override,3 temporarily disabled.
    let state: Int
    var enabled: Bool { state != 0 }
    var temporarilyOverridden: Bool { state == 2 || state == 3 }
}

/// Operational retention is distinct from the user's enabled OBC policy.
/// It is deliberately excluded from persisted policy/ownership comparisons.
struct NativeOptimizedChargingEngagement: Sendable, Equatable {
    let engaged: Bool
    let overrideAllowed: Bool
}

@MainActor
protocol MonthlyFullChargeControl {
    func temporaryFullChargeAvailable() throws -> Bool
    func readFullChargePolicy() throws -> NativeChargingPolicySnapshot
    func beginTemporaryFullCharge() throws -> NativeChargingPolicySnapshot
    func beginTemporaryFullCharge(expectedPolicy: NativeChargingPolicySnapshot) throws -> NativeChargingPolicySnapshot
    func canContinueTemporaryFullCharge() throws -> Bool
    func restoreAfterTemporaryFullCharge(_ policy: NativeChargingPolicySnapshot) throws -> NativeChargingPolicySnapshot
}

extension MonthlyFullChargeControl {
    func beginTemporaryFullCharge(expectedPolicy: NativeChargingPolicySnapshot) throws -> NativeChargingPolicySnapshot {
        guard try readFullChargePolicy().hasSamePolicy(as: expectedPolicy) else {
            throw NativeChargeLimitError.temporaryVerificationFailed("the charging policy changed before temporary charging")
        }
        return try beginTemporaryFullCharge()
    }
}

@MainActor
protocol NativeChargeLimitControl {
    func readState() throws -> NativeChargeLimitSnapshot
    func setLimit(_ limit: Int) throws -> NativeChargeLimitSnapshot
    func readOptimizedCharging() throws -> Bool
    func readOptimizedChargingState() throws -> NativeOptimizedChargingSnapshot
    func setOptimizedCharging(_ enabled: Bool) throws -> Bool
}

extension NativeChargeLimitControl {
    func readOptimizedCharging() throws -> Bool { throw NativeChargeLimitError.optimizedUnavailable }
    func readOptimizedChargingState() throws -> NativeOptimizedChargingSnapshot {
        NativeOptimizedChargingSnapshot(state: try readOptimizedCharging() ? 1 : 0)
    }
    func setOptimizedCharging(_ enabled: Bool) throws -> Bool { throw NativeChargeLimitError.optimizedUnavailable }
}

enum NativeChargeLimitError: LocalizedError, Equatable {
    case unavailable
    case invalidState(String)
    case unsupportedLimit(Int)
    case verificationFailed(requested: Int, actual: Int, enabled: Bool)
    case optimizedUnavailable
    case optimizedVerificationFailed(requested: Bool, actual: Bool)
    case temporaryUnavailable
    case temporaryVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The native macOS charge limit is unavailable."
        case .invalidState(let detail):
            return "The native charge limit returned invalid data: \(detail)."
        case .unsupportedLimit(let limit):
            return "macOS does not support a native charge limit of \(limit)%."
        case .verificationFailed(let requested, let actual, let enabled):
            return "macOS did not confirm the requested \(requested)% limit (effective limit: \(actual)%, enabled: \(enabled))."
        case .optimizedUnavailable:
            return "Native optimized battery charging is unavailable."
        case .optimizedVerificationFailed(let requested, let actual):
            return "macOS did not confirm optimized battery charging (requested: \(requested), actual: \(actual))."
        case .temporaryUnavailable:
            return "Native temporary full charging is unavailable."
        case .temporaryVerificationFailed(let detail):
            return "macOS did not confirm temporary full charging: \(detail)."
        }
    }
}

/// A raw boundary lets tests model malformed private-framework replies without
/// creating a PowerUI client. Only validated value types leave this service.
@MainActor
protocol NativeChargeLimitTransport {
    func readRawState() throws -> [String: Any]
    func applyLimit(_ limit: Int) throws
    func disable() throws
    func readRawOptimizedCharging() throws -> [String: Any]
    func applyOptimizedCharging(_ enabled: Bool) throws
    func temporaryFullChargeAvailable() throws -> Bool
    func readRawOptimizedChargingEngagement() throws -> [String: Any]
    func temporarilyOverrideOptimizedCharging() throws
    func temporarilyDisableChargeLimit(expectedLimit: Int) throws
}

extension NativeChargeLimitTransport {
    func readRawOptimizedCharging() throws -> [String: Any] { throw NativeChargeLimitError.optimizedUnavailable }
    func applyOptimizedCharging(_ enabled: Bool) throws { throw NativeChargeLimitError.optimizedUnavailable }
    func temporaryFullChargeAvailable() throws -> Bool { false }
    func readRawOptimizedChargingEngagement() throws -> [String: Any] { throw NativeChargeLimitError.temporaryUnavailable }
    func temporarilyOverrideOptimizedCharging() throws { throw NativeChargeLimitError.temporaryUnavailable }
    func temporarilyDisableChargeLimit(expectedLimit: Int) throws { throw NativeChargeLimitError.temporaryUnavailable }
}

@MainActor
final class PowerUINativeChargeLimitControl: NativeChargeLimitControl, MonthlyFullChargeControl {
    private let transport: any NativeChargeLimitTransport

    /// The bridge is lazy: constructing this service neither contacts PowerUI
    /// nor changes policy, including when the app is hosted by a test runner.
    init() {
        transport = PowerUINativeChargeLimitTransport()
    }

    init(transport: any NativeChargeLimitTransport) {
        self.transport = transport
    }

    func readState() throws -> NativeChargeLimitSnapshot {
        try Self.decode(transport.readRawState())
    }

    func setLimit(_ limit: Int) throws -> NativeChargeLimitSnapshot {
        guard (80...100).contains(limit) else { throw NativeChargeLimitError.unsupportedLimit(limit) }
        let before = try readState()
        guard before.availableLimits.contains(limit) else { throw NativeChargeLimitError.unsupportedLimit(limit) }
        if limit == 100 ? (!before.enabled && !before.isTemporaryOverride) : (before.enabled && before.limit == limit) {
            return before
        }
        if limit == 100 { try transport.disable() }
        else { try transport.applyLimit(limit) }
        let after = try readState()
        guard after.effectiveLimit == limit, limit != 100 || (!after.enabled && !after.isTemporaryOverride) else {
            throw NativeChargeLimitError.verificationFailed(requested: limit, actual: after.effectiveLimit, enabled: after.enabled)
        }
        return after
    }

    func readOptimizedCharging() throws -> Bool {
        try readOptimizedChargingState().enabled
    }

    func readOptimizedChargingState() throws -> NativeOptimizedChargingSnapshot {
        let raw = try transport.readRawOptimizedCharging()
        guard let supported = raw["supported"] as? NSNumber,
              CFGetTypeID(supported) == CFBooleanGetTypeID() else {
            throw NativeChargeLimitError.invalidState("optimized charging support is not a Boolean")
        }
        guard supported.boolValue else { throw NativeChargeLimitError.optimizedUnavailable }
        return NativeOptimizedChargingSnapshot(state: try Self.integer(raw["enabled"], field: "optimized charging state", range: 0...3, allowBoolean: true))
    }

    func setOptimizedCharging(_ enabled: Bool) throws -> Bool {
        let before = try readOptimizedChargingState()
        if before.enabled == enabled, !before.temporarilyOverridden { return before.enabled }
        try transport.applyOptimizedCharging(enabled)
        let after = try readOptimizedChargingState()
        guard after.enabled == enabled, !after.temporarilyOverridden else {
            throw NativeChargeLimitError.optimizedVerificationFailed(requested: enabled, actual: after.enabled)
        }
        return after.enabled
    }

    func temporaryFullChargeAvailable() throws -> Bool { try transport.temporaryFullChargeAvailable() }

    func readOptimizedChargingEngagement() throws -> NativeOptimizedChargingEngagement {
        let raw = try transport.readRawOptimizedChargingEngagement()
        guard try Self.boolean(raw["supported"], field: "optimized charging support") else {
            throw NativeChargeLimitError.optimizedUnavailable
        }
        return NativeOptimizedChargingEngagement(
            engaged: try Self.boolean(raw["engaged"], field: "optimized charging retention"),
            overrideAllowed: try Self.boolean(raw["overrideAllowed"], field: "optimized charging override permission")
        )
    }

    func canContinueTemporaryFullCharge() throws -> Bool {
        let optimized: NativeOptimizedChargingSnapshot
        do { optimized = try readOptimizedChargingState() }
        catch NativeChargeLimitError.optimizedUnavailable { return true }
        guard optimized.state == 1 else { return true }
        return try !readOptimizedChargingEngagement().engaged
    }

    func readFullChargePolicy() throws -> NativeChargingPolicySnapshot {
        let limit = try readState()
        let optimized: NativeOptimizedChargingSnapshot?
        do { optimized = try readOptimizedChargingState() }
        catch NativeChargeLimitError.optimizedUnavailable { optimized = nil }
        return NativeChargingPolicySnapshot(chargeLimit: limit, optimizedChargingEnabled: optimized?.enabled,
                                             optimizedChargingState: optimized?.state)
    }

    func beginTemporaryFullCharge() throws -> NativeChargingPolicySnapshot {
        try beginTemporaryFullCharge(matching: nil)
    }

    func beginTemporaryFullCharge(expectedPolicy: NativeChargingPolicySnapshot) throws -> NativeChargingPolicySnapshot {
        try beginTemporaryFullCharge(matching: expectedPolicy)
    }

    private func beginTemporaryFullCharge(matching expectedPolicy: NativeChargingPolicySnapshot?) throws -> NativeChargingPolicySnapshot {
        guard try temporaryFullChargeAvailable() else { throw NativeChargeLimitError.temporaryUnavailable }
        let previous = try readFullChargePolicy()
        if let expectedPolicy, !previous.hasSamePolicy(as: expectedPolicy) {
            throw NativeChargeLimitError.temporaryVerificationFailed("the charging policy changed before temporary charging")
        }
        guard !previous.chargeLimit.isTemporaryOverride,
              previous.optimizedChargingState != 2, previous.optimizedChargingState != 3 else {
            throw NativeChargeLimitError.temporaryVerificationFailed("another charging override is already active")
        }
        // Finish all capability/error/operational preflight before the first
        // write. Configuration1 alone does not make an OBC override admissible.
        var requestOptimizedOverride = false
        if let state = previous.optimizedChargingState {
            let engagement = try readOptimizedChargingEngagement()
            guard !engagement.engaged || (state == 1 && engagement.overrideAllowed) else {
                throw NativeChargeLimitError.temporaryUnavailable
            }
            requestOptimizedOverride = state == 1 && engagement.overrideAllowed
        }
        // OBC must precede MCL: changing MCL can change OBC's operational
        // eligibility. Verify OBC independently before touching the limit.
        if requestOptimizedOverride {
            try transport.temporarilyOverrideOptimizedCharging()
            guard try readOptimizedChargingState().state == 2 else {
                throw NativeChargeLimitError.temporaryVerificationFailed("the native temporary charging override was not confirmed")
            }
        }
        if previous.chargeLimit.enabled {
            try transport.temporarilyDisableChargeLimit(expectedLimit: previous.chargeLimit.limit)
        }
        let actual = try readFullChargePolicy()
        let expectedMCLState = previous.chargeLimit.enabled ? 3 : previous.chargeLimit.nativeFeatureState
        let expectedOBCState = requestOptimizedOverride ? 2 : previous.optimizedChargingState
        guard actual.chargeLimit.effectiveLimit == 100,
              actual.chargeLimit.nativeFeatureState == expectedMCLState,
              actual.optimizedChargingState == expectedOBCState,
              try canContinueTemporaryFullCharge() else {
            throw NativeChargeLimitError.temporaryVerificationFailed("the native temporary charging override was not confirmed")
        }
        return actual
    }

    func restoreAfterTemporaryFullCharge(_ policy: NativeChargingPolicySnapshot) throws -> NativeChargingPolicySnapshot {
        let before = try readFullChargePolicy()
        // A feature already at its canonical state has no temporary override
        // to release. Avoid rewriting an unchanged independent macOS feature.
        if before.chargeLimit.nativeFeatureState != policy.chargeLimit.nativeFeatureState ||
            before.chargeLimit.effectiveLimit != policy.chargeLimit.effectiveLimit {
            guard !policy.chargeLimit.isTemporaryOverride else {
                throw NativeChargeLimitError.temporaryVerificationFailed("the charging policy changed during restoration")
            }
            if policy.chargeLimit.enabled {
                guard policy.chargeLimit.availableLimits.contains(policy.chargeLimit.limit),
                      (80..<100).contains(policy.chargeLimit.limit) else {
                    throw NativeChargeLimitError.unsupportedLimit(policy.chargeLimit.limit)
                }
                try transport.applyLimit(policy.chargeLimit.limit)
            } else { try transport.disable() }
        }
        if before.optimizedChargingState != policy.optimizedChargingState, let optimized = policy.optimizedChargingEnabled,
           policy.optimizedChargingState == 0 || policy.optimizedChargingState == 1 {
            try transport.applyOptimizedCharging(optimized)
        }
        let actual = try readFullChargePolicy()
        guard actual.hasSamePolicy(as: policy) else {
            throw NativeChargeLimitError.temporaryVerificationFailed("the previous charging policy was not restored")
        }
        return actual
    }

    private static func decode(_ raw: [String: Any]) throws -> NativeChargeLimitSnapshot {
        guard let supported = raw["supported"] as? NSNumber,
              CFGetTypeID(supported) == CFBooleanGetTypeID() else {
            throw NativeChargeLimitError.invalidState("support flag is not a Boolean")
        }
        guard supported.boolValue else { throw NativeChargeLimitError.unavailable }
        guard let values = raw["availableLimits"] as? [Any], !values.isEmpty, values.count <= 21 else {
            throw NativeChargeLimitError.invalidState("available limits are empty or malformed")
        }
        let limits = try values.map { try integer($0, field: "available limit", range: 80...100) }.sorted()
        guard Set(limits).count == limits.count, limits.contains(100) else {
            throw NativeChargeLimitError.invalidState("available limits are duplicated or omit 100%")
        }
        let limit = try integer(raw["limit"], field: "stored limit", range: 0...100)
        let enabledValue = try integer(raw["enabled"], field: "native feature state", range: 0...3, allowBoolean: true)
        guard enabledValue != 2 else { throw NativeChargeLimitError.invalidState("unknown native feature state2") }
        let enabled = enabledValue == 1
        // PowerUI may retain an unset/previous limit while MCL is disabled.
        // Only an enabled policy must belong to the service's available list.
        guard !enabled || limits.contains(limit) else {
            throw NativeChargeLimitError.invalidState("enabled limit is not supported")
        }
        return NativeChargeLimitSnapshot(availableLimits: limits, limit: limit, enabled: enabled, nativeFeatureState: enabledValue)
    }

    private static func integer(_ value: Any?, field: String, range: ClosedRange<Int>, allowBoolean: Bool = false) throws -> Int {
        guard let number = value as? NSNumber,
              allowBoolean || CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw NativeChargeLimitError.invalidState("\(field) is not an integer")
        }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded(.towardZero) == raw,
              raw >= Double(range.lowerBound), raw <= Double(range.upperBound) else {
            throw NativeChargeLimitError.invalidState("\(field) is outside its valid range")
        }
        return Int(raw)
    }

    private static func boolean(_ value: Any?, field: String) throws -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw NativeChargeLimitError.invalidState("\(field) is not a Boolean")
        }
        return value.boolValue
    }
}

/// Objective-C contains exceptions and validates the dynamically loaded ABI.
/// Its mutation methods also refuse to run in XCTest/Swift Testing bundles.
@MainActor
final class PowerUINativeChargeLimitTransport: NativeChargeLimitTransport {
    private let bridge = ODNativeChargeLimitBridge()

    func readRawState() throws -> [String: Any] {
        var error: NSError?
        let result = bridge.readState(&error)
        if let error { throw error }
        guard let result else { throw NativeChargeLimitError.unavailable }
        return result
    }

    func applyLimit(_ limit: Int) throws {
        var error: NSError?
        let succeeded = bridge.applyLimit(limit, error: &error)
        if let error { throw error }
        guard succeeded else { throw NativeChargeLimitError.unavailable }
    }

    func disable() throws {
        var error: NSError?
        let succeeded = bridge.disable(&error)
        if let error { throw error }
        guard succeeded else { throw NativeChargeLimitError.unavailable }
    }

    func readRawOptimizedCharging() throws -> [String: Any] {
        var error: NSError?
        let result = bridge.readOptimizedCharging(&error)
        if let error { throw error }
        guard let result else { throw NativeChargeLimitError.optimizedUnavailable }
        return result
    }

    func applyOptimizedCharging(_ enabled: Bool) throws {
        var error: NSError?
        let succeeded = bridge.setOptimizedCharging(enabled, error: &error)
        if let error { throw error }
        guard succeeded else { throw NativeChargeLimitError.optimizedUnavailable }
    }

    func temporaryFullChargeAvailable() throws -> Bool {
        var error: NSError?
        let available = bridge.supportsTemporaryFullCharge(&error)
        if let error { throw error }
        return available
    }

    func readRawOptimizedChargingEngagement() throws -> [String: Any] {
        var error: NSError?
        let result = bridge.readOptimizedChargingEngagement(&error)
        if let error { throw error }
        guard let result else { throw NativeChargeLimitError.temporaryUnavailable }
        return result
    }

    func temporarilyOverrideOptimizedCharging() throws {
        var error: NSError?
        let succeeded = bridge.temporarilyOverrideOptimizedCharging(&error)
        if let error { throw error }
        guard succeeded else { throw NativeChargeLimitError.temporaryUnavailable }
    }

    func temporarilyDisableChargeLimit(expectedLimit: Int) throws {
        var error: NSError?
        let succeeded = bridge.temporarilyDisableChargeLimit(expectedLimit, error: &error)
        if let error { throw error }
        guard succeeded else { throw NativeChargeLimitError.temporaryUnavailable }
    }
}
