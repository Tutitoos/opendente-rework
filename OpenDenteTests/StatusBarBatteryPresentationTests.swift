import Foundation
import Testing
@testable import OpenDente

@Suite("Status bar energy indicators")
struct StatusBarBatteryPresentationTests {
    @Test(arguments: [ChargingMode.charging, .topUp, .paused, .sailing, .heatProtection])
    func requestedModeCannotInventObservedCharging(_ mode: ChargingMode) {
        let icon = presentation(state(pluggedIn: true), mode: mode)
        #expect(icon.powerState == .connectedNotCharging)
        #expect(icon.symbolName == "powerplug.fill")
        let charging = presentation(state(pluggedIn: true, charging: true), mode: mode)
        #expect(charging.powerState == .charging)
        #expect(charging.symbolName == "battery.100percent.bolt")
    }

    @Test(arguments: [
        (-5.0, StatusBarBatteryPresentation.PowerState.onBattery),
        (-0.1, .externalPower), (0.0, .externalPower), (0.1, .externalPower),
        (5.0, .charging), (Double.nan, .connectedNotCharging), (Double.infinity, .connectedNotCharging)
    ])
    func measuredFlowDistinguishesBatteryUseFromAdapterPower(_ power: Double, _ expected: StatusBarBatteryPresentation.PowerState) {
        #expect(presentation(state(pluggedIn: true, power: power)).powerState == expected)
    }

    @Test func pluggingInChargingPausingAndUnpluggingChangeTheIndicator() {
        let battery = presentation(state(pluggedIn: false))
        let charging = presentation(state(pluggedIn: true, charging: true))
        let adapter = presentation(state(pluggedIn: true, power: 0))
        #expect(battery.symbolName == "battery.50percent")
        #expect(charging.symbolName == "battery.100percent.bolt")
        #expect(adapter.symbolName == "powerplug.fill")
        #expect(adapter.powerState == .externalPower)
        #expect(presentation(state(pluggedIn: false)).powerState == .onBattery)
    }

    @Test func forcedDischargeAndMeasuredDrainDoNotClaimAdapterOnlyPower() {
        let forced = presentation(state(pluggedIn: true), mode: .discharging)
        let measured = presentation(state(pluggedIn: true, charging: true, power: -10))
        #expect(forced.powerState == .onBattery)
        #expect(measured.powerState == .onBattery)
        #expect(forced.symbolName == "battery.50percent")
        #expect(measured.symbolName == forced.symbolName)
    }

    @Test(arguments: [false, true])
    func lowPowerModeChangesColorWithoutChangingThePowerSymbol(showMode: Bool) {
        let normal = presentation(state(pluggedIn: true, charging: true), showMode: showMode)
        let saving = presentation(state(pluggedIn: true, charging: true, saving: true), showMode: showMode)
        #expect(!normal.usesLowPowerColor)
        #expect(saving.usesLowPowerColor)
        #expect(normal.symbolName == saving.symbolName)
        #expect(saving.symbolName == (showMode ? "battery.100percent.bolt" : "battery.50percent"))
        #expect(!presentation(state(pluggedIn: false)).usesLowPowerColor)
    }

    @Test func invalidReadingsStayNeutralEvenWithChargingAndLowPowerFlags() {
        var unavailable = state(pluggedIn: true, charging: true, saving: true)
        unavailable.hasValidBatteryReading = false
        let icon = presentation(unavailable)
        #expect(icon.powerState == .unavailable)
        #expect(icon.percentage == nil)
        #expect(icon.symbolName == "battery.0percent")
        #expect(!icon.usesLowPowerColor)
    }

    @Test func hiddenStatusUsesTheSelectedPercentageButPreservesActualAccessibleState() {
        let icon = StatusBarBatteryPresentation(state: state(pluggedIn: true, charging: true), mode: .paused,
                                               useHardwarePercentage: true, showMode: false)
        #expect(icon.percentage == 80)
        #expect(icon.symbolName == "battery.75percent")
        #expect(icon.powerState == .charging)
    }

    private func presentation(_ state: BatteryState, mode: ChargingMode = .idle,
                              showMode: Bool = true) -> StatusBarBatteryPresentation {
        StatusBarBatteryPresentation(state: state, mode: mode, useHardwarePercentage: false, showMode: showMode)
    }

    private func state(pluggedIn: Bool, charging: Bool = false, power: Double? = nil,
                       saving: Bool = false) -> BatteryState {
        BatteryState(percentage: 50, hardwarePercentage: 80, isCharging: charging, isPluggedIn: pluggedIn,
                     currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
                     temperature: nil, voltage: nil, amperage: nil, systemPower: nil, adapterPower: nil,
                     adapterInfo: nil, batteryPower: power, notChargingReason: nil, chargerInhibitReason: nil,
                     timeToEmpty: nil, timeToFull: nil, isLowPowerModeEnabled: saving)
    }
}
