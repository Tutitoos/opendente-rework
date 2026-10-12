import Foundation
import Testing
@testable import OpenDente

/// Calls the production parsers with fixtures; no SMC connection or subprocess is opened.
struct BatteryReadingTests {
    private func ui16(_ raw: UInt16, key: String = "TEST") -> SMCValue {
        SMCValue(key: key, dataSize: 2, dataType: "ui16",
                 bytes: [UInt8(raw & 0xff), UInt8(raw >> 8)])
    }

    private func resolve(full: SMCValue? = nil, design: SMCValue? = nil,
                         remaining: SMCValue? = nil,
                         format: SMCRemainingCapacityFormat = .unknown,
                         brsc: SMCValue? = nil, registry: [String: Any]? = nil,
                         percentage: Int? = 80) -> BatteryCapacitySnapshot {
        BatteryReadingParser.resolveCapacities(
            full: full, design: design, remaining: remaining, format: format,
            brsc: brsc, registry: registry, normalizedPercentage: percentage
        )
    }

    @Test func firmwareMetadataSelectsFormatOnce() {
        #expect(SMCRemainingCapacityFormat(bcf0Size: 1) == .modernLittleEndian)
        #expect(SMCRemainingCapacityFormat(bcf0Size: 4) == .legacyBigEndian)
        #expect(SMCRemainingCapacityFormat(bcf0Size: nil) == .unknown)
        #expect(SMCRemainingCapacityFormat(bcf0Size: 2) == .unknown)
    }

    @Test(arguments: [(UInt16(4608), 5502, 84), (UInt16(1024), 5502, 19), (UInt16(4618), 6000, 77)])
    func modernB0RMDoesNotSelectPlausibleWrongEndian(_ raw: UInt16, _ full: Int, _ expected: Int) {
        let result = resolve(full: ui16(UInt16(full)), design: ui16(6000),
                             remaining: ui16(raw), format: .modernLittleEndian)
        #expect(result.current == Int(raw))
        #expect(result.hardwarePercentage == expected)
        #expect(result.currentSource == .smc)
        #expect(!result.isEstimated)
    }

    @Test func legacyB0RMUsesBigEndianEvenWhenLittleEndianIsPlausible() {
        let value = SMCValue(key: "B0RM", dataSize: 2, dataType: "ui16", bytes: [0x12, 0x0a])
        #expect(BatteryReadingParser.remainingCapacity(value, format: .legacyBigEndian, full: 6000) == 4618)
        #expect(BatteryReadingParser.remainingCapacity(value, format: .modernLittleEndian, full: 6000) == 2578)
    }

    @Test func unknownB0RMContractUsesRawRegistryFallback() {
        let result = resolve(full: ui16(5502), design: ui16(5760), remaining: ui16(4608),
                             registry: ["RemainingCapacity": 4608])
        #expect(result.current == 4608)
        #expect(result.hardwarePercentage == 84)
        #expect(result.source == .smc)
        #expect(result.currentSource == .ioRegistry)
        #expect(!result.isEstimated)
    }

    @Test func unknownB0RMContractDoesNotInventHardwareZero() {
        let result = resolve(full: ui16(5502), design: ui16(5760), remaining: ui16(4608), percentage: 80)
        #expect(result.hardwarePercentage == nil)
        #expect(result.current == 4401)
        #expect(result.isEstimated)
        #expect(result.currentSource == .estimated)
    }

    @Test func missingRawRemainingKeepsVerifiedBRSCIndependentOfEstimate() {
        let brsc = SMCValue(key: "BRSC", dataSize: 1, dataType: "ui8 ", bytes: [76])
        let result = resolve(full: ui16(5502), design: ui16(5760), brsc: brsc, percentage: 80)
        #expect(result.hardwarePercentage == 76)
        #expect(result.current == 4401)
        #expect(result.isEstimated)
        #expect(result.source == .smc)
    }

    @Test func verifiedBRSCDoesNotRequireCapacitySensors() {
        let brsc = SMCValue(key: "BRSC", dataSize: 1, dataType: "ui8 ", bytes: [76])
        let result = resolve(brsc: brsc)
        #expect(result.hardwarePercentage == 76)
        #expect(result.full == nil && result.design == nil && result.current == nil)
        #expect(result.quality == .unavailable)
        #expect(!result.isEstimated)
    }

    @Test func unverifiedOrMalformedBRSCFormatsAreUnavailable() {
        for value in [ui16(76, key: "BRSC"),
                      SMCValue(key: "BRSC", dataSize: 1, dataType: "si8 ", bytes: [76]),
                      SMCValue(key: "BRSC", dataSize: 1, dataType: "ui8 ", bytes: []),
                      SMCValue(key: "BRSC", dataSize: 2, dataType: "ui8 ", bytes: [76, 0]),
                      SMCValue(key: "BRSC", dataSize: 1, dataType: "ui8 ", bytes: [101])] {
            #expect(BatteryReadingParser.hardwarePercentage(value) == nil)
        }
    }

    @Test func missingSMCUsesCompleteRawRegistryPair() {
        let result = resolve(registry: ["FullChargeCapacity": 5502, "DesignCapacity": 5760,
                                       "RemainingCapacity": 4198, "CurrentCapacity": 80, "MaxCapacity": 100])
        #expect(result.full == 5502 && result.design == 5760 && result.current == 4198)
        #expect(result.hardwarePercentage == 76)
        #expect(result.source == .ioRegistry && result.currentSource == .ioRegistry)
        #expect(result.quality == .valid)
        #expect(!result.isEstimated)
    }

    @Test func invalidSMCCapacitiesFallBackToValidRegistryPair() {
        let result = resolve(full: ui16(65535), design: ui16(5000),
                             registry: ["FullChargeCapacity": 5502, "DesignCapacity": 5760,
                                        "RemainingCapacity": 4198])
        #expect(result.full == 5502 && result.design == 5760)
        #expect(result.source == .ioRegistry && result.quality == .valid)
    }

    @Test func normalizedCapacityKeysNeverBecomeMilliampHours() {
        let result = resolve(registry: ["Max Capacity": 100, "Current Capacity": 80,
                                       "MaxCapacity": 100, "CurrentCapacity": 80])
        #expect(result.full == nil && result.design == nil && result.current == nil)
        #expect(result.hardwarePercentage == nil)
        #expect(result.quality == .unavailable)
        #expect(result.unavailableReason != nil)
    }

    @Test func partialPairsAreNotMixedAcrossSources() {
        let result = resolve(full: ui16(5502), registry: ["DesignCapacity": 5760])
        #expect(result.full == nil && result.design == nil)
        #expect(result.quality == .unavailable)
    }

    @Test(arguments: [(UInt16(65535), UInt16(5000)), (UInt16(65535), UInt16(65535)),
                      (UInt16(0), UInt16(5000)), (UInt16(5000), UInt16(0)),
                      (UInt16(7000), UInt16(5000)), (UInt16(100), UInt16(100))])
    func invalidPairsAreExplainedInsteadOfReportedAsHealth(_ full: UInt16, _ design: UInt16) {
        let result = resolve(full: ui16(full), design: ui16(design))
        #expect(result.full == nil && result.design == nil)
        #expect(result.quality == .invalid)
        #expect(result.unavailableReason?.contains("coherent") == true)
    }

    @Test func slightlyAboveDesignCapacityRemainsValid() {
        let result = resolve(full: ui16(5100), design: ui16(5000), remaining: ui16(5000),
                             format: .modernLittleEndian)
        #expect(result.full == 5100 && result.design == 5000)
        #expect(result.quality == .valid)
    }

    @Test func malformedCapacityMetadataIsRejected() {
        for value in [SMCValue(key: "B0FC", dataSize: 2, dataType: "si16", bytes: [0x7e, 0x15]),
                      SMCValue(key: "B0FC", dataSize: 2, dataType: "ui16", bytes: [0x7e]),
                      SMCValue(key: "B0FC", dataSize: 4, dataType: "ui16", bytes: [0x7e, 0x15, 0, 0])] {
            #expect(BatteryReadingParser.unsigned16(value) == nil)
            #expect(BatteryReadingParser.remainingCapacity(value, format: .modernLittleEndian, full: 5502) == nil)
            #expect(resolve(full: value, design: ui16(5760)).quality == .invalid)
        }
    }

    @Test func registryNumericValuesRejectBooleanNegativeFractionAndSentinel() {
        for raw in [true, -1, 12.5, 65535, "5502", Double.nan] as [Any] {
            #expect(BatteryReadingParser.registryInteger(raw) == nil)
        }
        #expect(BatteryReadingParser.registryInteger(NSNumber(value: 5502)) == 5502)
        #expect(BatteryReadingParser.registryInteger(0) == 0)
    }

    @Test func measuredZeroIsValidButIncoherentRemainingIsNot() {
        let empty = resolve(full: ui16(5502), design: ui16(5760), remaining: ui16(0),
                            format: .modernLittleEndian)
        #expect(empty.current == 0 && empty.hardwarePercentage == 0)
        #expect(!empty.isEstimated)
        let invalid = resolve(full: ui16(5502), design: ui16(5760), remaining: ui16(65535),
                              format: .modernLittleEndian, registry: ["RemainingCapacity": -1], percentage: 101)
        #expect(invalid.current == nil && invalid.hardwarePercentage == nil)
        #expect(!invalid.isEstimated)
    }

    @Test func unavailableIOPSDoesNotCreateAnEstimatedEmptyBattery() {
        let missing = IOPSBatteryParser.parse([])
        let result = resolve(full: ui16(5502), design: ui16(5760), percentage: missing.percentage)
        #expect(result.current == nil && result.hardwarePercentage == nil)
        #expect(result.currentSource == .unavailable)
        #expect(!result.isEstimated)
        let genuinelyEmpty = resolve(full: ui16(5502), design: ui16(5760), percentage: 0)
        #expect(genuinelyEmpty.current == 0 && genuinelyEmpty.isEstimated)
    }
}

struct IOPSBatteryReadingTests {
    private func source(type: String = "InternalBattery", current: Any = 80, maximum: Any = 100,
                        present: Any = true, charging: Any = false,
                        power: String = "AC Power") -> [String: Any] {
        ["Type": type, "Is Present": present, "Current Capacity": current,
         "Max Capacity": maximum, "Is Charging": charging, "Power Source State": power]
    }

    @Test func firstUPSDoesNotSupplyMacPercentageOrCondition() {
        var ups = source(type: "UPS", current: 3000, maximum: 4000, power: "Battery Power")
        ups["BatteryHealth"] = "Poor"
        var battery = source(current: 40, maximum: 50)
        battery["BatteryHealth"] = "Good"
        let result = IOPSBatteryParser.parse([ups, battery])
        #expect(result.percentage == 80)
        #expect(result.isPluggedIn)
        #expect(result.hasValidBatteryReading)
        #expect(result.systemHealth.condition == .normal)
    }

    @Test func absentInternalAndUPSOnlyDoNotInventZeroPercent() {
        for descriptions in [[], [source(type: "UPS")], [source(present: false)],
                             [source(type: "UPS"), source(present: false)]] {
            let result = IOPSBatteryParser.parse(descriptions)
            #expect(result.percentage == nil)
            #expect(!result.hasValidBatteryReading)
            #expect(!result.isPluggedIn && !result.isCharging)
            #expect(result.systemHealth.condition == .unknown)
        }
    }

    @Test(arguments: [(40, 50, 80), (75, 150, 50), (1, 3, 33), (0, 100, 0), (100, 100, 100)])
    func capacitiesAreNormalizedBeforeTheyReachControl(_ current: Int, _ maximum: Int, _ expected: Int) {
        let result = IOPSBatteryParser.parse([source(current: current, maximum: maximum)])
        #expect(result.percentage == expected)
        #expect(result.hasValidBatteryReading)
    }

    @Test func missingAndMalformedCoreFieldsAreUnavailable() {
        let valid = source()
        for key in ["Type", "Is Present", "Current Capacity", "Max Capacity", "Is Charging", "Power Source State"] {
            var missing = valid
            missing.removeValue(forKey: key)
            #expect(!IOPSBatteryParser.parse([missing]).hasValidBatteryReading)
        }
        for malformed in [source(current: true), source(current: "80"), source(current: -1),
                          source(current: 100.5), source(current: Double.infinity), source(current: 101),
                          source(current: Double.greatestFiniteMagnitude, maximum: Double.greatestFiniteMagnitude),
                          source(maximum: 0), source(maximum: -1), source(maximum: true),
                          source(present: 1), source(charging: 0), source(power: "Unknown")] {
            #expect(IOPSBatteryParser.parse([malformed]).percentage == nil)
        }
    }

    @Test func invalidInternalEntryDoesNotHideLaterValidBattery() {
        let result = IOPSBatteryParser.parse([source(maximum: 0), source(current: 60, power: "Battery Power")])
        #expect(result.percentage == 60)
        #expect(!result.isPluggedIn)
        #expect(result.hasValidBatteryReading)
    }

    @Test func optionalTelemetryDoesNotBecomeInvalidSignedValues() {
        var battery = source()
        battery["CycleCount"] = 37
        battery["Time to Empty"] = -1
        battery["Time to Full Charge"] = 60
        let result = IOPSBatteryParser.parse([battery])
        #expect(result.cycleCount == 37)
        #expect(result.timeToEmpty == nil)
        #expect(result.timeToFull == 60)
    }
}

struct SystemBatteryHealthTests {
    private func json(_ health: [String: Any], key: String = "battery_health_info") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["SPPowerDataType": [[key: health]]])
    }

    @Test func nativeGoodAndMaximumAreSeparateFromRawCapacityRatio() throws {
        let data = try json(["sppower_battery_health": "Good",
                             "sppower_battery_health_maximum_capacity": "100\u{00a0}%"])
        let health = SystemBatteryHealthParser.systemProfiler(data)
        #expect(health?.condition == .normal)
        #expect(health?.maximumCapacityPercentage == 100)
        #expect(health?.source == .systemProfiler)
    }

    @Test func alternateHealthDictionaryKeyIsSupported() throws {
        let data = try json(["sppower_battery_health": "Service Recommended",
                             "sppower_battery_health_maximum_capacity": 78], key: "sppower_battery_health_info")
        let health = SystemBatteryHealthParser.systemProfiler(data)
        #expect(health?.condition == .serviceRecommended)
        #expect(health?.maximumCapacityPercentage == 78)
    }

    @Test func maximumWithoutConditionDoesNotInventNormal() throws {
        let health = SystemBatteryHealthParser.systemProfiler(try json([
            "sppower_battery_health": "Undocumented", "sppower_battery_health_maximum_capacity": "95%"
        ]))
        #expect(health?.condition == .unknown)
        #expect(health?.maximumCapacityPercentage == 95)
    }

    @Test func failedMalformedOrMissingProfilerHealthIsUnavailable() throws {
        #expect(SystemBatteryHealthParser.systemProfiler(Data()) == nil)
        #expect(SystemBatteryHealthParser.systemProfiler(Data("not JSON".utf8)) == nil)
        #expect(SystemBatteryHealthParser.systemProfiler(Data("{}".utf8)) == nil)
        #expect(SystemBatteryHealthParser.systemProfiler(try json([:])) == nil)
        #expect(SystemBatteryHealthParser.systemProfiler(try json([
            "sppower_battery_health": "Undocumented", "sppower_battery_health_maximum_capacity": "NaN"
        ])) == nil)
    }

    @Test func nativeMaximumRejectsInvalidFormatsAndValues() {
        for raw in [true, "101%", "-1%", "100.5%", "NaN", "1e2", "1%0%0", "100%%", Double.infinity, 101] as [Any] {
            #expect(SystemBatteryHealthParser.maximumCapacity(raw) == nil)
        }
        #expect(SystemBatteryHealthParser.maximumCapacity(" 98 % ") == 98)
        #expect(SystemBatteryHealthParser.maximumCapacity(100) == 100)
    }

    @Test func iopsStateOfChargeIsNotNativeHealth() {
        let health = SystemBatteryHealthParser.iops(["Max Capacity": 100, "Current Capacity": 80])
        #expect(health.condition == .unknown)
        #expect(health.maximumCapacityPercentage == nil)
    }

    @Test func iopsFailureOverridesReportedGood() {
        let internalFailure = SystemBatteryHealthParser.iops(["BatteryHealth": "Good", "Internal Failure": true])
        #expect(internalFailure.condition == .serviceRecommended)
        let failureModes = SystemBatteryHealthParser.iops(["BatteryHealth": "Good", "BatteryFailureModes": ["Permanent Failure"]])
        #expect(failureModes.condition == .serviceRecommended)
        let condition = SystemBatteryHealthParser.iops(["BatteryHealth": "Good", "BatteryHealthCondition": "Check Battery"])
        #expect(condition.condition == .serviceRecommended)
    }

    @Test func recognizedIopsGoodIsReportedWithItsSource() {
        let health = SystemBatteryHealthParser.iops(["BatteryHealth": "Good"])
        #expect(health.condition == .normal && health.source == .iops)
    }

    @Test func cacheExpiresAtTTLAndRejectsFutureSamples() {
        let now = Date(timeIntervalSince1970: 1_000)
        var cache = SystemBatteryHealthCache()
        let good = SystemBatteryHealth(condition: .normal, maximumCapacityPercentage: 100, source: .systemProfiler)
        cache.record(good, at: now)
        #expect(cache.value(at: now)?.condition == .normal)
        #expect(cache.value(at: now.addingTimeInterval(599)) == good)
        #expect(cache.value(at: now.addingTimeInterval(600)) == nil)
        #expect(cache.value(at: now.addingTimeInterval(-1)) == nil)
    }

    @Test func failedRefreshImmediatelyClearsCachedGood() {
        let now = Date(timeIntervalSince1970: 1_000)
        var cache = SystemBatteryHealthCache()
        cache.record(SystemBatteryHealth(condition: .normal, maximumCapacityPercentage: 100,
                                         source: .systemProfiler), at: now)
        cache.record(nil, at: now.addingTimeInterval(300))
        #expect(cache.value(at: now.addingTimeInterval(301)) == nil)
        #expect(cache.updatedAt == nil)
        #expect(cache.health == nil)
    }

    @Test func subprocessFailureDoesNotProduceHealthData() {
        let runner = SystemHealthCommandRunner()
        #expect(runner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", "exit 7"], timeout: 1) == nil)
    }

    @Test func subprocessHasAHardDeadline() {
        let start = Date()
        let runner = SystemHealthCommandRunner()
        let result = runner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"),
                                arguments: ["10"], timeout: 0.1)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func cancelledSubprocessDoesNotReturnLateSuccess() {
        let runner = SystemHealthCommandRunner()
        let cancellation = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        cancellation.schedule(deadline: .now() + 0.1)
        cancellation.setEventHandler { runner.cancel() }
        cancellation.resume()
        defer { cancellation.cancel() }
        let start = Date()
        let result = runner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"),
                                arguments: ["10"], timeout: 10)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func successfulOwnedCommandOutputUsesTheProductionHealthParser() {
        let runner = SystemHealthCommandRunner()
        let fixture = #"{"SPPowerDataType":[{"battery_health_info":{"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"100%"}}]}"#
        let output = runner.run(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                arguments: [fixture], timeout: 1)
        #expect(output != nil)
        let parsed = output.flatMap(SystemBatteryHealthParser.systemProfiler)
        #expect(parsed?.condition == .normal)
        #expect(parsed?.maximumCapacityPercentage == 100)
    }
}
