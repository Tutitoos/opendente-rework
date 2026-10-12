import SwiftUI

/// Main popover content shown when clicking the status bar icon
struct PopoverView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared
    @ObservedObject var settings = AppSettings.shared
    let onOpenSettings: () -> Void

    private var canControlCharging: Bool {
        charging.canControlChargeLimit
    }

    private var nativeLimitPresentation: NativeChargeLimitPresentation {
        NativeChargeLimitPresentation(
            requestedLimit: settings.chargeLimit,
            effectiveLimit: charging.effectiveNativeChargeLimit,
            availableLimits: charging.availableNativeChargeLimits,
            error: charging.localizedNativeChargeLimitError,
            isTemporaryOverride: charging.isNativeChargeLimitTemporarilyOverridden
        )
    }

    private var displayedLimit: Int? {
        charging.isUsingNativeChargeLimit ? charging.effectiveNativeChargeLimit : settings.chargeLimit
    }

    private var displayedMode: ChargingMode {
        guard canControlCharging else {
            return battery.batteryState.isCharging ? .charging : battery.batteryState.isPluggedIn ? .idle : .onBattery
        }
        return charging.mode
    }

    private var displayPercentage: Int {
        battery.batteryState.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
    }

    private var adapterVisible: Bool {
        Self.adapterVisible(isPluggedIn: battery.batteryState.isPluggedIn, mode: displayedMode)
    }

    /// Adapter details show when charger is connected — including during force discharge
    /// where isPluggedIn may be false (IOKit reports battery source) but charger is physically present.
    static func adapterVisible(isPluggedIn: Bool, mode: ChargingMode) -> Bool {
        isPluggedIn || mode == .discharging
    }

    private var canDischarge: Bool {
        charging.supportsSMCControls && battery.batteryState.hasValidBatteryReading && Self.canDischarge(
            isPluggedIn: battery.batteryState.isPluggedIn,
            percentage: displayPercentage,
            chargeLimit: settings.chargeLimit,
            isHelperInstalled: charging.isHelperInstalled,
            chargingAPI: charging.chargingAPI
        )
    }

    /// Pure function for testability
    static func canDischarge(isPluggedIn: Bool, percentage: Int, chargeLimit: Int, isHelperInstalled: Bool, chargingAPI: SMCChargingAPI) -> Bool {
        isPluggedIn && percentage > chargeLimit && isHelperInstalled && chargingAPI != .unknown
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            batteryBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if settings.showPowerFlow {
                PowerFlowView(battery: battery.batteryState, mode: displayedMode)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !charging.isUsingNativeChargeLimit && !charging.isHelperInstalled {
                helperWarning
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if !charging.isUsingNativeChargeLimit && charging.isHelperInstalled && !canControlCharging {
                ChargingControlNotice(isHelperInstalled: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if charging.isUsingNativeChargeLimit {
                NativeChargeLimitNotice(presentation: nativeLimitPresentation, compact: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if charging.supportsSMCControls && charging.systemChargeLimitConflict {
                systemLimitWarning
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            detailsGrid
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .environment(\.locale, language.locale)
        .frame(width: 320)
    }

    private var hasControlWarning: Bool {
        if charging.isUsingNativeChargeLimit {
            return nativeLimitPresentation.hasWarning
        }
        return !canControlCharging || charging.systemChargeLimitConflict
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(charging.isUsingNativeChargeLimit ? nativeLimitPresentation.localizedLimitLabel
                     : canControlCharging ? L10n.format("Limit: %d%%", settings.chargeLimit) : L10n.tr("Battery Monitor"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Image(systemName: hasControlWarning ? "exclamationmark.triangle.fill" : displayedMode.statusBarIcon)
                        .font(.system(size: 10))
                    Text(charging.isUsingNativeChargeLimit
                         ? nativeLimitPresentation.localizedStatusLabel(observedMode: displayedMode)
                         : !canControlCharging ? L10n.tr("Control Unavailable") : charging.systemChargeLimitConflict
                         ? L10n.tr("System Limit Active") : L10n.tr(displayedMode.displayName))
                        .font(.system(size: 11))
                }
                .foregroundStyle(hasControlWarning ? .orange : .secondary)
            }

            Spacer()

            if charging.supportsSMCControls && charging.mode == .topUp {
                Button(action: { charging.cancelTopUp() }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help(L10n.tr("Cancel Top Up"))
            } else if charging.supportsSMCControls && charging.mode == .discharging {
                Button(action: { charging.stopDischarge() }) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help(L10n.tr("Stop Discharge"))
            } else {
                Button(action: { charging.startTopUp() }) {
                    Image(systemName: "arrow.up.to.line.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!battery.batteryState.hasValidBatteryReading || !battery.batteryState.isPluggedIn || !charging.supportsSMCControls)
                .help(L10n.tr(charging.isUsingNativeChargeLimit ? "Choose 100% below to change the native limit" : "Top Up to 100%"))

                Button(action: { charging.startDischarge() }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canDischarge)
                .help(L10n.tr(charging.isUsingNativeChargeLimit ? "Force discharge requires SMC charging control" : "Discharge to Limit"))
            }

            Button(action: { openSettings() }) {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Open Settings"))
        }
    }

    // MARK: - Battery Bar

    private var batteryBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let percentage = CGFloat(displayPercentage) / 100.0
            let limitPosition = CGFloat(displayedLimit ?? settings.chargeLimit) / 100.0
            let sailingLower = CGFloat(settings.sailingLowerBound) / 100.0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternarySystemFill))

                RoundedRectangle(cornerRadius: 6)
                    .fill(batteryColor)
                    .frame(width: width * percentage)

                if charging.supportsSMCControls && settings.sailingModeEnabled {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: width * sailingLower)
                }

                if canControlCharging && displayedLimit != nil {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: width * limitPosition - 1)
                }

                HStack {
                    modeIcon
                        .font(.system(size: 11, weight: .bold))
                    Text(battery.batteryState.hasValidBatteryReading ? "\(displayPercentage)%" : L10n.tr("Unavailable"))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(percentage > 0.3 ? .white : .primary)
                .padding(.leading, 8)
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var modeIcon: some View {
        switch displayedMode {
        case .charging, .topUp:
            Image(systemName: "bolt.fill")
        case .discharging:
            Image(systemName: "bolt.fill")
                .rotationEffect(.degrees(180))
        case .sailing:
            Image(systemName: "wind")
        case .heatProtection:
            Image(systemName: "thermometer.sun.fill")
        default:
            EmptyView()
        }
    }

    private var batteryColor: Color {
        switch displayedMode {
        case .charging, .topUp:
            return .green
        case .discharging:
            return .orange
        case .heatProtection:
            return .red
        case .sailing:
            return .blue
        default:
            if displayPercentage <= 20 {
                return .red
            }
            return .green
        }
    }

    // MARK: - Details Grid

    private var detailsGrid: some View {
        let state = battery.batteryState
        let items = settings.popoverDetailItems

        return VStack(spacing: 6) {
            ForEach(items) { item in
                if item == .batteryHealth {
                    BatteryHealthCard(presentation: BatteryHealthPresentation(
                        applePercentage: state.systemMaximumCapacityPercentage,
                        openDentePercentage: state.healthPercentage
                    ), compact: true)
                    detailRow("Battery Condition", value: state.batteryCondition.displayName)
                } else if let row = detailValue(for: item, state: state) {
                    detailRow(row.label, value: row.value)
                }
            }

            if !battery.smcAvailable {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(L10n.tr("SMC not available — detailed data unavailable"))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
    }

    private func detailValue(for item: PopoverDetailItem, state: BatteryState) -> (label: String, value: String)? {
        switch item {
        case .temperature:
            guard let temp = state.temperature else { return nil }
            return ("Temperature", L10n.temperature(temp))
        case .batteryHealth:
            return ("Capacity / Design", state.healthPercentage.map { L10n.format("%.1f%%", $0) } ?? "Unavailable")
        case .cycleCount:
            guard let cycles = state.cycleCount else { return nil }
            return ("Cycle Count", L10n.number(Double(cycles), fractionDigits: 0))
        case .timeRemaining:
            guard canControlCharging else { return nil }
            guard let limit = displayedLimit else { return nil }
            return displayedMode.timeRemainingDisplay(
                chargeLimit: limit,
                percentage: displayPercentage,
                timeToFull: state.timeToFull,
                timeToEmpty: state.timeToEmpty
            )
        case .systemPower:
            guard let power = state.systemPower, power > 0 else { return nil }
            return ("System Power", L10n.format("%.1f W", power))
        case .adapterPower:
            guard adapterVisible, let power = state.adapterPower, power > 0 else { return nil }
            if let max = state.adapterInfo?.watts, max > 0 {
                return ("Adapter Power", L10n.format("%.1f W of %d W", power, max))
            }
            return ("Adapter Power", L10n.format("%.1f W", power))
        case .adapterName:
            guard adapterVisible, let info = state.adapterInfo else { return nil }
            return ("Adapter", info.name)
        case .adapterManufacturer:
            guard adapterVisible, let mfr = state.adapterInfo?.manufacturer else { return nil }
            return ("Manufacturer", mfr)
        case .adapterModel:
            guard adapterVisible, let model = state.adapterInfo?.model else { return nil }
            return ("Model", model)
        case .adapterSerial:
            guard adapterVisible, let serial = state.adapterInfo?.serial else { return nil }
            return ("Serial", serial)
        case .adapterVoltage:
            guard adapterVisible, let info = state.adapterInfo else { return nil }
            return ("Adapter Voltage", L10n.format("%.2f V", info.voltage))
        case .adapterCurrent:
            guard adapterVisible, let info = state.adapterInfo else { return nil }
            return ("Adapter Current", L10n.format("%.3f A", info.current))
        case .voltage:
            guard let voltage = state.voltage else { return nil }
            return ("Battery Voltage", L10n.format("%.2f V", voltage))
        case .amperage:
            guard let amperage = state.amperage else { return nil }
            return ("Battery Current", L10n.format("%.3f A", amperage))
        case .currentCapacity:
            guard let current = state.currentCapacity, let max = state.maxCapacity else { return ("Capacity", "Unavailable") }
            return (state.isCurrentCapacityEstimated ? "Capacity (Estimated)" : "Capacity", "\(L10n.number(Double(current), fractionDigits: 0)) / \(L10n.number(Double(max), fractionDigits: 0)) mAh")
        case .designCapacity:
            guard let design = state.designCapacity else { return nil }
            return ("Design Capacity", L10n.number(Double(design), fractionDigits: 0) + " mAh")
        case .batteryPower:
            guard let power = state.batteryPower else { return nil }
            return ("Battery Power", L10n.format("%.1f W", power))
        case .notChargingReason:
            guard let reason = state.notChargingReason, reason != 0 else { return nil }
            return ("Not Charging", L10n.format("0x%016llX", reason))
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(localizedDetailLabel(label))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(localizedDetailValue(value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 6) {
                if charging.isUsingNativeChargeLimit {
                    Picker(L10n.tr("Native Limit"), selection: Binding(
                        get: { nativeLimitPresentation.selection },
                        set: { _ = charging.setChargeLimit($0) }
                    )) {
                        ForEach(nativeLimitPresentation.choices, id: \.self) { limit in
                            Text("\(limit)%").tag(limit)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!canControlCharging || nativeLimitPresentation.choices.isEmpty)
                    .help(L10n.tr("Apply macOS Charge Limit"))
                } else {
                    Text("\(settings.chargeLimit)%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(width: 35)

                    Slider(
                        value: Binding(
                            get: { Double(settings.chargeLimit) },
                            set: { _ = charging.setChargeLimit(Int(($0 / 5).rounded() * 5)) }
                        ),
                        in: 20...100
                    )
                    .controlSize(.small)
                    .disabled(!canControlCharging)
                    .help(L10n.tr(canControlCharging ? "Charge Limit" : "Saved limit; charging control is unavailable"))
                }
            }

            Spacer()

            Button(L10n.tr("Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helper Warning

    private var needsHelperApproval: Bool {
        HelperInstaller.status == .requiresApproval
    }

    private var helperWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(L10n.tr(needsHelperApproval
                 ? "Helper needs approval in System Settings"
                 : "Helper not installed — charging control unavailable"))
                .font(.system(size: 10))
            Spacer()
            if needsHelperApproval {
                Button(L10n.tr("Approve")) {
                    HelperInstaller.openSystemSettings()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button(L10n.tr("Install")) {
                    openSettings()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .foregroundStyle(.orange)
    }

    // MARK: - System Limit Warning

    private var systemLimitWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(L10n.tr("macOS Charge Limit is preventing charging"))
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer()
            Button(L10n.tr("Open")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            }
            .font(.system(size: 10))
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .foregroundStyle(.orange)
    }

    // MARK: - Actions

    private func openSettings() {
        onOpenSettings()
    }

    private func localizedDetailLabel(_ label: String) -> String {
        if label.hasPrefix("Time to "), let limit = displayedLimit {
            return L10n.format("Time to %d%%", limit)
        }
        return L10n.tr(label)
    }

    private func localizedDetailValue(_ value: String) -> String {
        L10n.tr(value)
    }
}
