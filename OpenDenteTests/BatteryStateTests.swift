import XCTest
@testable import OpenDente

@MainActor
final class BatteryStateTests: XCTestCase {

    // MARK: - Health Percentage

    func testHealthPercentage_normalBattery() {
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: 4500, designCapacity: 5000, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.healthPercentage!, 90.0, accuracy: 0.1)
    }

    func testHealthPercentage_newBatteryCanExceed100() {
        // New batteries can report slightly above design capacity — this is real data, not a bug
        let state = BatteryState(
            percentage: 100, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: 5100, designCapacity: 5000, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.healthPercentage!, 102.0, accuracy: 0.1)
    }

    func testHealthPercentage_nilWhenMissingData() {
        let state = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.healthPercentage)
    }

    func testHealthPercentage_nilWhenDesignCapacityZero() {
        let state = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: 5000, designCapacity: 0, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.healthPercentage)
    }

    // MARK: - Power Source

    // MARK: - Effective Percentage

    func testHealthPercentageRejectsInvalidCapacityPairs() {
        for (full, design) in [(0, 5000), (-1, 5000), (5000, -1),
                               (65535, 5000), (65535, 65535), (7000, 5000), (100, 100)] {
            XCTAssertNil(capacityState(full: full, design: design).healthPercentage,
                         "Invalid pair \(full)/\(design) should not become battery health")
        }
    }

    func testRawRatioIsIndependentOfChargeAndNativeCondition() {
        var full = capacityState(full: 5502, design: 5760, percentage: 100)
        var empty = capacityState(full: 5502, design: 5760, percentage: 0)
        full.systemMaximumCapacityPercentage = 100
        full.batteryCondition = .normal
        empty.systemMaximumCapacityPercentage = 78
        empty.batteryCondition = .serviceRecommended
        XCTAssertEqual(full.healthPercentage, empty.healthPercentage)
        XCTAssertEqual(full.healthPercentage!, 95.520833, accuracy: 0.000001)
        XCTAssertEqual(full.systemMaximumCapacityPercentage, 100)
        XCTAssertEqual(empty.batteryCondition, .serviceRecommended)
    }

    func testUnknownHealthDoesNotClaimNormal() {
        XCTAssertEqual(BatteryState.unknown.batteryCondition, .unknown)
        XCTAssertNil(BatteryState.unknown.systemMaximumCapacityPercentage)
        XCTAssertEqual(BatteryState.unknown.batteryConditionSource, .unavailable)
        XCTAssertEqual(PopoverDetailItem.batteryHealth.displayName, "Capacity / Design")
        XCTAssertFalse(BatteryState.unknown.hasValidBatteryReading)
        XCTAssertEqual(BatteryState.unknown.statusBarText(effectivePercentage: 0, showPercentage: true,
                                                         showTemperature: false, showPower: false), "—")
    }

    func testEffectivePercentage_usesHardwareWhenEnabled() {
        let state = makeBatteryState(percentage: 78, hardwarePercentage: 81)
        XCTAssertEqual(state.effectivePercentage(useHardware: true), 81)
    }

    func testEffectivePercentage_fallsBackWhenHardwareNil() {
        let state = makeBatteryState(percentage: 78, hardwarePercentage: nil)
        XCTAssertEqual(state.effectivePercentage(useHardware: true), 78)
    }

    func testEffectivePercentage_usesMacOSWhenDisabled() {
        let state = makeBatteryState(percentage: 78, hardwarePercentage: 81)
        XCTAssertEqual(state.effectivePercentage(useHardware: false), 78)
    }

    // MARK: - Power Source

    func testIsOnBattery() {
        let pluggedIn = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertFalse(pluggedIn.isOnBattery)

        let onBattery = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertTrue(onBattery.isOnBattery)
    }

    // MARK: - USBPDProfile

    func testUSBPDProfile_wattsCalculation() {
        let profile = USBPDProfile(voltage: 20.0, current: 4.69)
        XCTAssertEqual(profile.watts, 94)  // 20 * 4.69 = 93.8 → rounds to 94
    }

    func testUSBPDProfile_wattsRoundsCorrectly() {
        let profile5v = USBPDProfile(voltage: 5.0, current: 2.96)
        XCTAssertEqual(profile5v.watts, 15)  // 14.8 → 15

        let profile9v = USBPDProfile(voltage: 9.0, current: 2.98)
        XCTAssertEqual(profile9v.watts, 27)  // 26.82 → 27

        let profile15v = USBPDProfile(voltage: 15.0, current: 2.99)
        XCTAssertEqual(profile15v.watts, 45)  // 44.85 → 45
    }

    // MARK: - AdapterInfo

    func testAdapterInfo_equality() {
        let a = makeAdapterInfo(name: "96W USB-C Power Adapter", watts: 94)
        let b = makeAdapterInfo(name: "96W USB-C Power Adapter", watts: 94)
        XCTAssertEqual(a, b)
    }

    func testAdapterInfo_inequalityOnName() {
        let a = makeAdapterInfo(name: "96W USB-C Power Adapter", watts: 94)
        let b = makeAdapterInfo(name: "30W USB-C Charger", watts: 30)
        XCTAssertNotEqual(a, b)
    }

    func testBatteryState_adapterInfoAccessible() {
        let adapter = makeAdapterInfo(name: "96W USB-C Power Adapter", watts: 94)
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: true, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: 18.3, adapterInfo: adapter,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.adapterInfo?.name, "96W USB-C Power Adapter")
        XCTAssertEqual(state.adapterInfo?.watts, 94)
        XCTAssertEqual(state.adapterInfo?.voltage, 20.0)
        XCTAssertEqual(state.adapterInfo?.current, 4.69)
        XCTAssertEqual(state.adapterPower, 18.3)
    }

    func testBatteryState_adapterInfoNilWhenUnplugged() {
        let state = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.adapterInfo)
    }

    // MARK: - notChargingReason

    func testNotChargingReason_zeroIsNormal() {
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: 0, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        // Zero means no issue — views should hide this
        XCTAssertEqual(state.notChargingReason, 0)
    }

    func testNotChargingReason_uint64Range() {
        // IORegistry can return large UInt64 values via ChargerData
        let largeReason: UInt64 = 0x0000_0001_0000_0000
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: largeReason, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.notChargingReason, largeReason)
        XCTAssertEqual(String(format: "0x%016llX", state.notChargingReason!), "0x0000000100000000")
    }

    // MARK: - systemChargeLimitActive

    func testSystemChargeLimitActive_nilIsFalse() {
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertFalse(state.systemChargeLimitActive)
    }

    func testSystemChargeLimitActive_zeroIsFalse() {
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: 0, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertFalse(state.systemChargeLimitActive)
    }

    func testSystemChargeLimitActive_systemLimitBit24True() {
        // NotChargingReason bit 24 (0x1000000) = system-level inhibit
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: 0x1000000, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertTrue(state.systemChargeLimitActive)
    }

    func testSystemChargeLimitActive_ourCHTEBitDoesNotTrigger() {
        // NotChargingReason bit 55 (0x80000000000000) = our CHTE inhibit — NOT system
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, adapterInfo: nil,
            batteryPower: nil, notChargingReason: 0x80000000000000, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertFalse(state.systemChargeLimitActive)
    }

    // MARK: - Helpers

    private func capacityState(full: Int, design: Int, percentage: Int = 50) -> BatteryState {
        BatteryState(percentage: percentage, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
                     currentCapacity: nil, maxCapacity: full, designCapacity: design, cycleCount: nil,
                     temperature: nil, voltage: nil, amperage: nil,
                     systemPower: nil, adapterPower: nil, adapterInfo: nil,
                     batteryPower: nil, notChargingReason: nil, chargerInhibitReason: nil,
                     timeToEmpty: nil, timeToFull: nil)
    }

    private func makeAdapterInfo(name: String, watts: Int) -> AdapterInfo {
        AdapterInfo(
            name: name, description: "pd charger", manufacturer: "Apple Inc.",
            model: "0x7002", watts: watts, voltage: 20.0, current: 4.69,
            serial: "ABC123", firmware: "01090058", isWireless: false,
            usbPDProfiles: [
                USBPDProfile(voltage: 5.0, current: 2.96),
                USBPDProfile(voltage: 9.0, current: 2.98),
                USBPDProfile(voltage: 15.0, current: 2.99),
                USBPDProfile(voltage: 20.0, current: 4.69),
            ],
            activeProfileIndex: 3
        )
    }
}
