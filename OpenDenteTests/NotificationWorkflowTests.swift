import Foundation
import Testing
@testable import OpenDente

@MainActor
struct NotificationWorkflowTests {
    private func withService(_ body: (NotificationService, RecordingNotificationSender, AppSettings) -> Void) {
        let name = "com.opendente.tests.events." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let sender = RecordingNotificationSender()
        body(NotificationService(sender: sender), sender, AppSettings(defaults: defaults))
    }

    @Test(arguments: [ChargingMode.idle, .paused, .onBattery])
    func leavingDischargeDoesNotInventCompletion(_ mode: ChargingMode) {
        withService { service, sender, settings in
            service.handleModeChange(from: .discharging, to: mode, settings: settings)
            #expect(sender.requests.isEmpty)
            service.handleChargingEvent(.dischargeCompleted, settings: settings)
            #expect(sender.requests.count == 1)
            #expect(service.lastEvent == .dischargeComplete)
        }
    }

    @Test func topUpCompletionIsDeliveredOncePerSession() {
        withService { service, sender, settings in
            let full = makeBatteryState(percentage: 100)
            for _ in 0..<2 {
                service.handleChargingEvent(.topUpStarted, settings: settings)
                service.handleModeChange(from: .paused, to: .topUp, settings: settings)
                service.handleBatteryState(full, mode: .topUp, settings: settings)
                service.handleBatteryState(full, mode: .topUp, settings: settings)
                service.handleModeChange(from: .topUp, to: .idle, settings: settings)
                service.handleModeChange(from: .idle, to: .paused, settings: settings)
            }
            #expect(sender.requests.count == 2)
        }
    }

    @Test func conflictMessageExplainsRaisingSystemLimit() {
        withService { service, sender, settings in
            service.send(.systemChargeLimitConflict, settings: settings)
            #expect(sender.requests.first?.content.body == L10n.tr("macOS Charge Limit is preventing charging. Raise it to your requested target or turn it off in System Settings > Battery."))
        }
    }

    @Test func unavailableControlCannotClaimSuccessfulChargingPolicies() {
        withService { service, sender, settings in
            service.handleModeChange(from: .charging, to: .paused, settings: settings, controlAvailable: false)
            service.handleModeChange(from: .paused, to: .heatProtection, settings: settings, controlAvailable: false)
            service.handleChargingEvent(.dischargeCompleted, settings: settings, controlAvailable: false)
            service.handleBatteryState(makeBatteryState(percentage: 100), mode: .topUp,
                                       settings: settings, controlAvailable: false)
            #expect(sender.requests.isEmpty)
            #expect(service.lastEvent == nil)

            service.handleModeChange(from: .paused, to: .heatProtection, settings: settings, controlAvailable: true)
            #expect(sender.requests.count == 1)
            #expect(service.lastEvent == .heatProtection)
        }
    }

    @Test func invalidBatteryReadingCannotCompleteTopUp() {
        withService { service, sender, settings in
            var state = makeBatteryState(percentage: 100, hardwarePercentage: 100)
            state.hasValidBatteryReading = false
            settings.useHardwareBatteryPercentage = true
            service.handleBatteryState(state, mode: .topUp, settings: settings)
            #expect(sender.requests.isEmpty)
            state.hasValidBatteryReading = true
            service.handleBatteryState(state, mode: .topUp, settings: settings)
            #expect(sender.requests.count == 1)
        }
    }

    @Test func failedDeliveryCanBeRetried() {
        withService { service, sender, settings in
            sender.error = NSError(domain: "test", code: 1)
            service.send(.heatProtection, settings: settings)
            #expect(service.lastEvent == nil)
            sender.error = nil
            service.send(.heatProtection, settings: settings)
            #expect(sender.requests.count == 2)
        }
    }

    @Test func oldDeliveryFailureDoesNotClearLaterSession() {
        withService { service, sender, settings in
            sender.defersDelivery = true
            service.send(.topUpComplete, settings: settings)
            service.handleChargingEvent(.topUpStarted, settings: settings)
            service.send(.topUpComplete, settings: settings)
            sender.completions[0](NSError(domain: "old-delivery", code: 1))
            #expect(service.lastEvent == .topUpComplete)
            service.send(.topUpComplete, settings: settings)
            #expect(sender.requests.count == 2)
        }
    }

    @Test(arguments: [ChargingMode.paused, .sailing, .heatProtection])
    func inhibitedModesStillDisplaySignificantBatteryContribution(_ mode: ChargingMode) {
        let state = BatteryState(percentage: 80, hardwarePercentage: nil,
                                 isCharging: false, isPluggedIn: true,
                                 currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
                                 temperature: nil, voltage: nil, amperage: nil,
                                 systemPower: 85, adapterPower: 67, adapterInfo: nil, batteryPower: -18,
                                 notChargingReason: nil, chargerInhibitReason: nil, timeToEmpty: nil, timeToFull: nil)
        #expect(PowerFlowView.resolveVisualState(battery: state, mode: mode) == .peakLoad)
    }
}
