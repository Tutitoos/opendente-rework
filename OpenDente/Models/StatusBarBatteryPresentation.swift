import AppKit

struct StatusBarBatteryPresentation {
    enum PowerState: String {
        case unavailable = "Battery reading unavailable"
        case onBattery = "On Battery"
        case charging = "Charging"
        case externalPower = "External Power"
        case connectedNotCharging = "Plugged In, Not Charging"
    }

    let powerState: PowerState
    let percentage: Int?
    let symbolName: String
    let usesLowPowerColor: Bool

    init(state: BatteryState, mode: ChargingMode, useHardwarePercentage: Bool, showMode: Bool) {
        percentage = state.hasValidBatteryReading ? state.effectivePercentage(useHardware: useHardwarePercentage) : nil
        usesLowPowerColor = state.hasValidBatteryReading && state.isLowPowerModeEnabled
        let power = state.batteryPower.flatMap { $0.isFinite ? $0 : nil }
        if !state.hasValidBatteryReading {
            powerState = .unavailable
        } else if !state.isPluggedIn || mode == .discharging || (power.map { $0 < -0.1 } ?? false) {
            powerState = .onBattery
        } else if state.isCharging || (power.map { $0 > 0.1 } ?? false) {
            powerState = .charging
        } else if power != nil {
            powerState = .externalPower
        } else {
            powerState = .connectedNotCharging
        }

        if showMode && powerState == .charging {
            symbolName = "battery.100percent.bolt"
        } else if showMode && (powerState == .externalPower || powerState == .connectedNotCharging) {
            symbolName = "powerplug.fill"
        } else {
            switch percentage ?? 0 {
            case 88...100: symbolName = "battery.100percent"
            case 63..<88: symbolName = "battery.75percent"
            case 38..<63: symbolName = "battery.50percent"
            case 13..<38: symbolName = "battery.25percent"
            default: symbolName = "battery.0percent"
            }
        }
    }

    @MainActor var accessibilityLabel: String {
        let description = percentage.map { L10n.format("OpenDente: battery %d%%, %@", $0, L10n.tr(powerState.rawValue)) }
            ?? L10n.tr(powerState.rawValue)
        return usesLowPowerColor ? description + ", " + L10n.tr("Low Power Mode") : description
    }

    @MainActor func makeImage() -> NSImage? {
        let size = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let configuration = usesLowPowerColor
            ? size.applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            : size
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        image?.isTemplate = !usesLowPowerColor
        return image
    }
}
