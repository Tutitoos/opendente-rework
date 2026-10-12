import Foundation
import Testing
@testable import OpenDente

@MainActor
struct HardwarePercentageControlTests {
    private func withManager(sailing: Bool, _ body: (ChargingManager, MockChargingControl, AppSettings, BatteryState) -> Void) {
        let name = "com.opendente.tests.hardware-limit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.sailingModeEnabled = sailing
        settings.controlMagSafeLED = false
        settings.showNotifications = false
        let helper = MockChargingControl()
        let manager = ChargingManager(settings: settings, helper: helper,
                                      battery: BatteryService(settings: settings), sleepAssertion: MockSleepAssertionControl())
        manager.isHelperInstalled = true
        manager.chargingAPI = .legacy
        let capacities = BatteryReadingParser.resolveCapacities(
            full: SMCValue(key: "B0FC", dataSize: 2, dataType: "ui16", bytes: [126, 21]),
            design: SMCValue(key: "B0DC", dataSize: 2, dataType: "ui16", bytes: [128, 22]),
            remaining: SMCValue(key: "B0RM", dataSize: 2, dataType: "ui16", bytes: [0, 18]),
            format: SMCRemainingCapacityFormat(bcf0Size: 1), brsc: nil, registry: nil, normalizedPercentage: 84)
        #expect(capacities.current == 4608)
        #expect(capacities.hardwarePercentage == 84)
        let state = makeBatteryState(percentage: 84, hardwarePercentage: capacities.hardwarePercentage,
                                    isCharging: true, isPluggedIn: true, temperature: 25)
        body(manager, helper, settings, state)
    }

    @Test(arguments: [true, false], [true, false])
    func aboveLimitPausesWithEitherPercentageSource(sailing: Bool, useHardware: Bool) {
        withManager(sailing: sailing) { manager, helper, settings, state in
            settings.useHardwareBatteryPercentage = useHardware
            manager.evaluateState(state)
            #expect(manager.mode == .paused)
            #expect(!helper.calls.contains(.enableCharging))
        }
    }

    @Test(arguments: [true, false])
    func selectingHardwarePercentageDoesNotResumeAboveLimit(sailing: Bool) {
        withManager(sailing: sailing) { manager, helper, settings, state in
            manager.evaluateState(state)
            #expect(manager.mode == .paused)
            helper.clearCalls()
            settings.useHardwareBatteryPercentage = true
            manager.evaluateState(state)
            #expect(manager.mode == .paused)
            #expect(!helper.calls.contains(.enableCharging))
        }
    }
}
