import SwiftUI
import ServiceManagement
import UserNotifications
import os.log

/// Settings window with tabbed interface
struct SettingsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if charging.isUsingNativeChargeLimit {
                NativeChargeLimitNotice(presentation: NativeChargeLimitPresentation(
                    requestedLimit: AppSettings.shared.chargeLimit,
                    effectiveLimit: charging.effectiveNativeChargeLimit,
                    availableLimits: charging.availableNativeChargeLimits,
                    error: charging.localizedNativeChargeLimitError,
                    isTemporaryOverride: charging.isNativeChargeLimitTemporarilyOverridden
                ))
                    .padding(12)
                Divider()
            } else if !charging.canControlChargeLimit {
                ChargingControlNotice(isHelperInstalled: charging.isHelperInstalled)
                    .padding(12)
                Divider()
            }

            TabView {
                GeneralTab()
                    .tabItem { Label(L10n.tr("General"), systemImage: "gear") }

                ChargingTab()
                    .tabItem { Label(L10n.tr("Charge"), systemImage: "bolt.fill") }

                NotificationsTab()
                    .tabItem { Label(L10n.tr("Notifications"), systemImage: "bell") }

                StatusBarTab()
                    .tabItem { Label(L10n.tr("Status Bar"), systemImage: "menubar.rectangle") }

                PopoverItemsTab()
                    .tabItem { Label(L10n.tr("Popover"), systemImage: "list.bullet") }

                BatteryInfoTab()
                    .tabItem { Label(L10n.tr("Battery"), systemImage: "battery.100percent") }

                HistoryTab()
                    .tabItem { Label(L10n.tr("History"), systemImage: "chart.xyaxis.line") }

                EventLogTab()
                    .tabItem { Label(L10n.tr("Event Log"), systemImage: "list.bullet.rectangle") }
            }
        }
        .environment(\.locale, language.locale)
        .frame(minWidth: 640, idealWidth: 680)
    }
}

/// Read-only battery data can be available even when charging control is unsupported.
struct ChargingControlNotice: View {
    @ObservedObject private var language = LanguageManager.shared
    let isHelperInstalled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Charging control unavailable")).fontWeight(.semibold)
                Text(L10n.tr(isHelperInstalled
                     ? "No supported charging API was detected. OpenDente cannot enforce a charge limit or heat protection on this Mac. Battery monitoring remains available."
                     : "Install and approve the helper to enable charging control. Battery monitoring remains available."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
    }
}

/// The effective native limit is a system policy, not merely the saved requested value.
struct NativeChargeLimitPresentation {
    let requestedLimit: Int
    let effectiveLimit: Int?
    let availableLimits: [Int]
    let error: String?
    let isTemporaryOverride: Bool

    init(requestedLimit: Int, effectiveLimit: Int?, availableLimits: [Int], error: String?,
         isTemporaryOverride: Bool = false) {
        self.requestedLimit = requestedLimit
        self.effectiveLimit = effectiveLimit
        self.availableLimits = availableLimits
        self.error = error
        self.isTemporaryOverride = isTemporaryOverride
    }

    var choices: [Int] {
        Array(Set(availableLimits.filter { (80...100).contains($0) })).sorted()
    }

    var selection: Int {
        if choices.contains(requestedLimit) { return requestedLimit }
        if let effectiveLimit, choices.contains(effectiveLimit) { return effectiveLimit }
        return choices.first ?? requestedLimit
    }

    /// Only a successful native state-3 readback explains a temporary 100% limit.
    var hasConfirmedTemporaryFullCharge: Bool {
        isTemporaryOverride && effectiveLimit == 100 && error == nil
    }

    var hasUnappliedRequest: Bool { effectiveLimit != requestedLimit && !hasConfirmedTemporaryFullCharge }
    var hasWarning: Bool { error != nil || effectiveLimit == nil || hasUnappliedRequest }
    var effectiveLimitLabel: String { effectiveLimit.map { "\($0)%" } ?? "Unavailable" }
    var limitLabel: String {
        hasConfirmedTemporaryFullCharge
            ? "Usual: \(requestedLimit)% · Temporary: 100%"
            : "Native limit: \(effectiveLimitLabel)"
    }

    @MainActor var localizedLimitLabel: String {
        if hasConfirmedTemporaryFullCharge {
            return L10n.format("Usual: %d%% · Temporary: %d%%", requestedLimit, 100)
        }
        return L10n.format("Native limit: %@", L10n.tr(effectiveLimitLabel))
    }

    @MainActor var localizedTemporaryLimitExplanation: String {
        L10n.format("Temporarily charging to %d%%; usual limit: %d%%.", 100, requestedLimit)
    }

    func statusLabel(observedMode: ChargingMode) -> String {
        if error != nil { return "Native control error" }
        if effectiveLimit == nil { return "Native limit unavailable" }
        if hasConfirmedTemporaryFullCharge { return "Temporary Full Charge" }
        if hasUnappliedRequest { return "Requested limit not active" }
        return observedMode.displayName
    }

    @MainActor func localizedStatusLabel(observedMode: ChargingMode) -> String {
        L10n.tr(statusLabel(observedMode: observedMode))
    }
}

struct NativeChargeLimitNotice: View {
    @ObservedObject private var language = LanguageManager.shared
    let presentation: NativeChargeLimitPresentation
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = presentation.error {
                Text(L10n.format("Native charge limit: %@", L10n.tr(error)))
                    .foregroundStyle(.orange)
            }
            if presentation.hasConfirmedTemporaryFullCharge {
                Text(presentation.localizedTemporaryLimitExplanation)
                    .foregroundStyle(.secondary)
            }
            if presentation.hasUnappliedRequest {
                Text(L10n.format("Requested %d%%; effective limit: %@.", presentation.requestedLimit,
                                 L10n.tr(presentation.effectiveLimitLabel)))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.tr(compact
                 ? "macOS controls charging; the native limit persists during sleep and after quitting."
                 : "macOS applies the charge limit. It may resume after the battery drops more than 5% and occasionally charge to 100% for calibration. The limit persists during sleep and after quitting OpenDente."))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared
    @StateObject private var loginItem = LoginItemController(settings: AppSettings.shared)

    var body: some View {
        Form {
            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Language"), selection: $language.selection) {
                    ForEach(LanguageSelection.allCases) { selection in
                        Text(selection == .system ? L10n.tr("System") : selection.displayName).tag(selection)
                    }
                }
                Text(L10n.tr("Changes apply immediately. System uses the language selected in macOS."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.tr("Launch at Login"), isOn: Binding(
                    get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }
                ))
                if let error = loginItem.errorMessage {
                    Text(loginItem.errorSource.map { L10n.error($0) } ?? L10n.tr(error)).font(.caption).foregroundStyle(.orange)
                }
                if loginItem.requiresApproval {
                    Button(L10n.tr("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }

            Section {
                LabeledContent(L10n.tr("Version")) {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                HelperStatusPanel()

                if !charging.isHelperInstalled {
                    helperActions

                    Text(L10n.tr("The helper daemon is required for SMC charging controls. The native macOS charge limit works without it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    @ViewBuilder
    private var helperActions: some View {
        let status = HelperInstaller.status
        if status == .requiresApproval {
            Button(L10n.tr("Open System Settings")) {
                HelperInstaller.openSystemSettings()
            }
            Text(L10n.tr("Toggle OpenDente ON in Login Items to approve the helper."))
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Button(L10n.tr("Install Helper")) {
                if HelperInstaller.register() {
                    charging.connectToHelper()
                    HelperStatusMonitor.shared.refresh()
                }
            }
        }
    }

}

// MARK: - Notifications Tab

struct NotificationsTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(L10n.tr("Enable Notifications"), isOn: $settings.showNotifications)
            }

            Section(L10n.tr("Events")) {
                Toggle(L10n.tr("Charge Limit Reached"), isOn: $settings.notifyChargeLimitReached)
                Toggle(L10n.tr("Top Up Complete (100%)"), isOn: $settings.notifyTopUpComplete)
                    .disabled(!charging.supportsSMCControls)
                Toggle(L10n.tr("Heat Protection Active"), isOn: $settings.notifyHeatProtection)
                    .disabled(!charging.supportsSMCControls)
                Toggle(L10n.tr("Discharge Complete"), isOn: $settings.notifyDischargeComplete)
                    .disabled(!charging.supportsSMCControls)
            }
            .disabled(!settings.showNotifications)

            #if DEBUG
            Section(L10n.tr("Test")) {
                Button(L10n.tr("Send Test Notification")) {
                    sendTestNotification()
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }

    #if DEBUG
    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "OpenDente Test"
        content.body = "Notifications are working!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.opendente.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    #endif
}

// MARK: - Charging Tab

struct ChargingTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared
    @ObservedObject private var monthly = MonthlyFullChargeService.shared

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

    var body: some View {
        Form {
            Section(L10n.tr("Charge Limit")) {
                if charging.isUsingNativeChargeLimit {
                    Picker(L10n.tr(nativeLimitPresentation.hasConfirmedTemporaryFullCharge ? "Usual Limit" : "Native Limit"), selection: Binding(
                        get: { nativeLimitPresentation.selection },
                        set: { _ = charging.setChargeLimit($0) }
                    )) {
                        ForEach(nativeLimitPresentation.choices, id: \.self) { limit in
                            Text("\(limit)%").tag(limit)
                        }
                    }
                    .disabled(nativeLimitPresentation.choices.isEmpty)
                    if nativeLimitPresentation.error != nil && !nativeLimitPresentation.choices.isEmpty {
                        Button(L10n.format("Apply %d%%", nativeLimitPresentation.selection)) {
                            _ = charging.setChargeLimit(nativeLimitPresentation.selection)
                        }
                    }
                    LabeledContent(L10n.tr("Effective Limit"), value: L10n.tr(nativeLimitPresentation.effectiveLimitLabel))
                    if nativeLimitPresentation.hasConfirmedTemporaryFullCharge {
                        Text(nativeLimitPresentation.localizedTemporaryLimitExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if nativeLimitPresentation.hasUnappliedRequest {
                        Text(L10n.format("Requested: %d%%. This limit is not active in macOS.", settings.chargeLimit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(L10n.tr("Limit"))
                        Slider(
                            value: Binding(
                                get: { Double(settings.chargeLimit) },
                                set: { _ = charging.setChargeLimit(Int(($0 / 5).rounded() * 5)) }
                            ),
                            in: 20...100
                        )
                        Text("\(settings.chargeLimit)%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 45, alignment: .trailing)
                    }
                }
            }
            .disabled(!canControlCharging)

            optimizedChargingSection
            monthlyChargingSection

            if charging.isUsingNativeChargeLimit {
                Section {
                    Text(L10n.tr("Sailing, heat protection, force discharge, MagSafe LED and sleep controls require SMC support. The native charge limit remains active during sleep and after quitting OpenDente."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.tr("Sailing Mode")) {
                Toggle(L10n.tr("Enable Sailing Mode"), isOn: $settings.sailingModeEnabled)

                if settings.sailingModeEnabled {
                    HStack {
                        Text(L10n.tr("Range"))
                        Slider(
                            value: Binding(
                                get: { Double(settings.sailingRange) },
                                set: { settings.sailingRange = Int($0.rounded()) }
                            ),
                            in: 2...25
                        )
                        Text("\(settings.sailingRange)%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 35, alignment: .trailing)
                    }
                    Text(L10n.format("Won't recharge until battery drops to %d%%", settings.sailingLowerBound))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!charging.supportsSMCControls)

            Section(L10n.tr("Heat Protection")) {
                Toggle(L10n.tr("Enable Heat Protection"), isOn: $settings.heatProtectionEnabled)

                if settings.heatProtectionEnabled {
                    HStack {
                        Text(L10n.tr("Max Temperature"))
                        Slider(
                            value: Binding(
                                get: { TemperatureDisplay.toDisplay(settings.heatProtectionTemp) },
                                set: {
                                    let step = TemperatureDisplay.sliderStep
                                    let snapped = ($0 / step).rounded() * step
                                    settings.heatProtectionTemp = TemperatureDisplay.toCelsius(snapped)
                                }
                            ),
                            in: TemperatureDisplay.sliderRange
                        )
                        Text(L10n.temperature(settings.heatProtectionTemp, fractionDigits: 0))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            .disabled(!charging.supportsSMCControls)

            Section(L10n.tr("Other")) {
                Toggle(L10n.tr("Automatic Discharge"), isOn: $settings.automaticDischarge)
                Toggle(L10n.tr("Control MagSafe LED"), isOn: $settings.controlMagSafeLED)
                if settings.controlMagSafeLED {
                    Toggle(L10n.tr("Turn off LED when not charging"), isOn: $settings.magSafeLEDOffWhenInactive)
                        .padding(.leading, 16)
                    Text(L10n.tr("Off when limit reached/sailing, orange when charging. Otherwise green/orange."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                } else {
                    Text(L10n.tr("Orange when charging, green when limit reached. Requires MagSafe."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(L10n.tr("Stop Charging when Sleeping"), isOn: $settings.stopChargingWhenSleeping)
                Text(L10n.tr("Inhibits charging before sleep so the battery stays at its current level."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L10n.tr("Disable Sleep until Charge Limit"), isOn: $settings.disableSleepUntilChargeLimit)
                Text(L10n.tr("Keeps Mac awake while charging or discharging toward the limit."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!charging.supportsSMCControls)

            Section(L10n.tr("Battery Percentage")) {
                Toggle(L10n.tr("Use Hardware Battery Percentage"), isOn: $settings.useHardwareBatteryPercentage)
                if charging.isUsingNativeChargeLimit {
                    Text(L10n.tr("Native limits use the macOS-reported percentage. This setting changes the displayed percentage only."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { charging.refreshNativeChargingPolicy() }
    }

    private var optimizedChargingSection: some View {
        Section(L10n.tr("Optimized Battery Charging")) {
            if let enabled = charging.optimizedChargingEnabled {
                Toggle(L10n.tr("Optimized Battery Charging"), isOn: Binding(
                    get: { charging.optimizedChargingEnabled ?? enabled },
                    set: { _ = charging.setOptimizedChargingEnabled($0) }
                ))
                .disabled(!charging.canControlOptimizedCharging)
            } else {
                LabeledContent(L10n.tr("Status"), value: "—")
            }
            Text(L10n.tr("macOS learns your charging routine and may delay charging beyond 80% until you need the battery."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = charging.localizedOptimizedChargingError {
                Text(L10n.tr(error)).font(.caption).foregroundStyle(.orange)
            }
            if !charging.canControlOptimizedCharging {
                Text(L10n.tr("Optimized charging control is unavailable on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L10n.tr("Refresh macOS Settings")) { charging.refreshNativeChargingPolicy() }
        }
    }

    private var monthlyChargingSection: some View {
        Section(L10n.tr("Monthly Full Charge")) {
            Toggle(L10n.tr("Charge to 100% once a month"), isOn: Binding(
                get: { monthly.enabled }, set: { monthly.setEnabled($0) }
            ))
            .disabled(!monthly.canStart && !monthly.enabled)
            LabeledContent(L10n.tr("Status"), value: monthlyStatusLabel)
            LabeledContent(L10n.tr("Last Full Charge"), value: monthly.lastFullChargeDate.map { L10n.date($0, includeTime: true) } ?? "—")
            if monthly.enabled {
                DatePicker(L10n.tr("Next Full Charge"), selection: Binding(
                    get: { monthly.nextChargeDate ?? Date() },
                    set: { monthly.setNextChargeDate($0) }
                ), displayedComponents: [.date, .hourAndMinute])
                .disabled(monthly.nextChargeDate == nil || monthly.isCharging)
                if monthly.isCharging || monthly.status == .waitingForPower {
                    Button(L10n.tr("Cancel This Full Charge")) { monthly.cancel() }
                }
            }
            if monthly.status == .failed {
                Button(L10n.tr("Retry")) { monthly.retry() }
            }
            if let error = monthly.localizedErrorMessage {
                Text(L10n.tr(error)).font(.caption).foregroundStyle(.orange)
            }
            Text(L10n.tr("Runs while OpenDente is active and the Mac is plugged in. The usual limit is restored when the battery reaches 100%, or when you cancel."))
                .font(.caption).foregroundStyle(.secondary)
            if !monthly.canStart {
                Text(L10n.tr("Monthly full charging requires native charging support on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monthlyStatusLabel: String {
        let label = switch monthly.status {
        case .disabled: "Disabled"
        case .scheduled: "Scheduled"
        case .waitingForPower: "Waiting for Power Adapter"
        case .charging: "Charging to 100%"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
        return L10n.tr(label)
    }
}

// MARK: - Status Bar Tab

struct StatusBarTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section(L10n.tr("Show in Status Bar")) {
                Toggle(L10n.tr("Battery Percentage"), isOn: $settings.statusBarShowPercentage)
                Toggle(L10n.tr("Temperature"), isOn: $settings.statusBarShowTemperature)
                Toggle(L10n.tr("Power Usage"), isOn: $settings.statusBarShowPower)
                Toggle(L10n.tr("Charging Mode Icon"), isOn: $settings.statusBarShowMode)
            }

            Section {
                Text(L10n.tr("Preview:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: statusBarIcon)
                        .font(.system(size: 15))
                    if !statusBarPreview.isEmpty {
                        Text(statusBarPreview)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
        .formStyle(.grouped)
    }

    private var statusBarIcon: String {
        let state = battery.batteryState
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        let mode: ChargingMode = charging.canControlChargeLimit ? charging.mode : .idle
        return settings.statusBarShowMode
            ? mode.batteryIconName(percentage: pct, isCharging: state.isCharging)
            : ChargingMode.idle.batteryIconName(percentage: pct, isCharging: false)
    }

    private var statusBarPreview: String {
        let state = battery.batteryState
        return L10n.statusBarText(state, settings: settings)
    }
}

// MARK: - Popover Items Tab

struct PopoverItemsTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var enabledItems: [PopoverDetailItem] = []
    @State private var disabledItems: [PopoverDetailItem] = []

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("Drag to reorder. Toggle to show/hide."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            List {
                Section {
                    Toggle(L10n.tr("Show Power Flow"), isOn: $settings.showPowerFlow)
                }

                Section(L10n.tr("Visible")) {
                    ForEach(enabledItems) { item in
                        PopoverItemRow(item: item, isEnabled: true) {
                            disableItem(item)
                        }
                    }
                    .onMove { from, to in
                        enabledItems.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                }

                Section(L10n.tr("Hidden")) {
                    ForEach(disabledItems) { item in
                        PopoverItemRow(item: item, isEnabled: false) {
                            enableItem(item)
                        }
                    }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        enabledItems = settings.popoverDetailItems
        let enabledSet = Set(enabledItems.map(\.rawValue))
        disabledItems = PopoverDetailItem.allCases.filter { !enabledSet.contains($0.rawValue) }
    }

    private func save() {
        settings.popoverDetailItems = enabledItems
    }

    private func disableItem(_ item: PopoverDetailItem) {
        enabledItems.removeAll { $0 == item }
        disabledItems.append(item)
        save()
    }

    private func enableItem(_ item: PopoverDetailItem) {
        disabledItems.removeAll { $0 == item }
        enabledItems.append(item)
        save()
    }
}

struct PopoverItemRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let item: PopoverDetailItem
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 18)

            Text(L10n.tr(item == .batteryHealth ? "Apple and OpenDente Capacity" : item.displayName))
                .foregroundStyle(isEnabled ? .primary : .secondary)

            Spacer()

            Button(action: onToggle) {
                Image(systemName: isEnabled ? "eye.fill" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(isEnabled ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format(isEnabled ? "Hide %@" : "Show %@", L10n.tr(item.displayName)))
        }
    }
}

// MARK: - Battery Info Tab

struct BatteryInfoTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let state = battery.batteryState

        Form {
            Section(L10n.tr("Battery Health")) {
                BatteryHealthCard(presentation: BatteryHealthPresentation(
                    applePercentage: state.systemMaximumCapacityPercentage,
                    openDentePercentage: state.healthPercentage
                ))
                Text(L10n.tr("Apple reports the maximum capacity from macOS. OpenDente divides full charge capacity by design capacity. The values can differ."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.tr("Battery")) {
                infoRow("macOS Percentage", value: state.hasValidBatteryReading ? "\(state.percentage)%" : "Unavailable")
                validatedRow("Hardware SoC", raw: state.hardwarePercentage, format: { "\($0)%" })
                if let current = state.currentCapacity, let max = state.maxCapacity {
                    validatedRow(state.isCurrentCapacityEstimated ? "Capacity (Estimated)" : "Capacity", value: "\(L10n.number(Double(current), fractionDigits: 0)) / \(L10n.number(Double(max), fractionDigits: 0)) mAh",
                                 warn: max < 500 || max > 20000 || current < 0 || current > max * 11 / 10)
                } else {
                    infoRow("Capacity", value: "Unavailable")
                }
                validatedRow("Design Capacity", raw: state.designCapacity, format: { L10n.number(Double($0), fractionDigits: 0) + " mAh" },
                             warn: { $0 < 500 || $0 > 20000 })
                if let health = state.healthPercentage {
                    infoRow("Full Capacity / Design", value: L10n.format("%.1f%%", health))
                } else {
                    validatedRow("Full Capacity / Design", value: "Unavailable",
                                 warn: state.healthDataQuality == .invalid)
                    Text(L10n.tr(state.capacityUnavailableReason ?? "Capacity data is unavailable."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.tr("The capacity ratio uses full charge capacity and design capacity. It can differ from the maximum capacity reported by macOS."))
                    .font(.caption).foregroundStyle(.secondary)
                infoRow("Capacity Source", value: state.capacitySource.displayName)
                infoRow("Remaining Capacity Source", value: state.currentCapacitySource.displayName)
                infoRow("macOS Maximum Capacity", value: state.systemMaximumCapacityPercentage.map { "\($0)%" } ?? "Unavailable")
                infoRow("Maximum Capacity Source", value: state.systemMaximumCapacitySource.displayName)
                validatedRow("Battery Condition", value: state.batteryCondition.displayName,
                             warn: state.batteryCondition == .serviceRecommended)
                infoRow("Condition Source", value: state.batteryConditionSource.displayName)
                validatedRow("Cycle Count", raw: state.cycleCount, format: { L10n.number(Double($0), fractionDigits: 0) },
                             warn: { $0 < 0 || $0 >= 10000 })
                validatedRow("Temperature", raw: state.temperature,
                             format: { L10n.temperature($0) },
                             warn: { $0 < -20 || $0 > 100 })
            }

            Section(L10n.tr("Battery Power")) {
                infoRow("Source", value: state.powerSource)
                validatedRow("Battery Voltage", raw: state.voltage,
                             format: { L10n.format("%.2f V", $0) },
                             warn: { $0 < 1 || $0 > 30 })
                validatedRow("Battery Current", raw: state.amperage,
                             format: { L10n.format("%.3f A", $0) },
                             warn: { abs($0) > 10 })
                validatedRow("Battery Power", raw: state.batteryPower,
                             format: { L10n.format("%.1f W", $0) },
                             warn: { abs($0) > 200 })
            }

            Section(L10n.tr("System Power")) {
                validatedRow("System Power", raw: state.systemPower,
                             format: { L10n.format("%.1f W", $0) },
                             warn: { $0 < 0 || $0 > 200 })
                validatedRow("Adapter Power", raw: state.adapterPower,
                             format: { L10n.format("%.1f W", $0) },
                             warn: { $0 < 0 || $0 > 200 })
            }

            if PopoverView.adapterVisible(isPluggedIn: state.isPluggedIn, mode: charging.mode), let adapter = state.adapterInfo {
                Section(L10n.tr("Adapter")) {
                    infoRow("Name", value: adapter.name)
                    if let desc = adapter.description {
                        infoRow("Description", value: desc)
                    }
                    if let mfr = adapter.manufacturer {
                        infoRow("Manufacturer", value: mfr)
                    }
                    if let model = adapter.model {
                        infoRow("Model", value: model)
                    }
                    infoRow("Wattage", value: "\(adapter.watts) W")
                    validatedRow("Voltage", raw: adapter.voltage,
                                 format: { L10n.format("%.2f V", $0) },
                                 warn: { $0 < 1 || $0 > 30 })
                    validatedRow("Current", raw: adapter.current,
                                 format: { L10n.format("%.3f A", $0) },
                                 warn: { abs($0) > 10 })
                    if !adapter.usbPDProfiles.isEmpty {
                        infoRow("Protocol", value: "USB-PD")
                    }
                    if let serial = adapter.serial {
                        infoRow("Serial", value: serial)
                    }
                    if let firmware = adapter.firmware {
                        infoRow("Firmware", value: firmware)
                    }
                    if adapter.isWireless {
                        infoRow("Wireless", value: "Yes")
                    }
                }

                if !adapter.usbPDProfiles.isEmpty {
                    Section(L10n.tr("USB-PD Profiles")) {
                        ForEach(Array(adapter.usbPDProfiles.enumerated()), id: \.offset) { index, profile in
                            HStack {
                                Text(L10n.format("%.0fV \u{00D7} %.2fA (%dW)",
                                            profile.voltage, profile.current, profile.watts))
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                if index == adapter.activeProfileIndex {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                if let reason = state.notChargingReason, reason != 0 {
                    Section {
                        infoRow("Not Charging Reason", value: L10n.format("0x%016llX", reason))
                    }
                }
            }

            Section(L10n.tr("Control")) {
                infoRow("Mode", value: charging.isUsingNativeChargeLimit
                        ? L10n.format("%@ (macOS)", L10n.tr(charging.mode.displayName))
                        : charging.canControlChargeLimit ? charging.mode.displayName : "Control Unavailable")
                infoRow("Charging API", value: chargingAPIName)
                if charging.isUsingNativeChargeLimit {
                    infoRow("Effective Native Limit", value: charging.effectiveNativeChargeLimit.map { "\($0)%" } ?? "Unavailable")
                    infoRow("Available Native Limits", value: charging.availableNativeChargeLimits.map { "\($0)%" }.joined(separator: ", "))
                    if let error = charging.localizedNativeChargeLimitError {
                        infoRow("Native Limit Error", value: error)
                    }
                }
                if charging.supportsSMCControls && settings.controlMagSafeLED {
                    infoRow("MagSafe LED", value: ledColorName)
                }
                infoRow("SMC Available", value: battery.smcAvailable ? "Yes" : "No")
                if let version = charging.helperVersion {
                    infoRow("Helper Version", value: version)
                }
            }

            Section {
                Button(L10n.tr("Export Diagnostic Report...")) {
                    DiagnosticExporter.exportWithSavePanel()
                }
                Text(L10n.tr("Exports system info, current state, settings, and recent logs as a text file for troubleshooting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var chargingAPIName: String {
        if charging.isUsingNativeChargeLimit { return "macOS Native (PowerUI)" }
        switch charging.chargingAPI {
        case .legacy: return "Legacy (CH0B/CH0C)"
        case .tahoe:  return "Tahoe (CHTE/CHIE)"
        case .unknown: return "Unavailable (not detected)"
        }
    }

    private var ledColorName: String {
        switch charging.lastLEDColor {
        case HelperConstants.ledAuto:   return "Auto"
        case HelperConstants.ledOff:    return "Off"
        case HelperConstants.ledGreen:  return "Green"
        case HelperConstants.ledOrange: return "Orange"
        default: return charging.lastLEDColor.map { L10n.format("0x%02X", $0) } ?? "–"
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        LabeledContent(L10n.tr(label)) {
            Text(L10n.tr(value))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    /// Show a value with warning if out of expected range, or "–" if unavailable
    private func validatedRow<T>(_ label: String, raw: T?, format: (T) -> String, warn: ((T) -> Bool)? = nil) -> some View {
        LabeledContent(L10n.tr(label)) {
            if let val = raw {
                let isWarning = warn?(val) ?? false
                Text(format(val))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isWarning ? .orange : .primary)
                    .textSelection(.enabled)
            } else {
                Text(L10n.tr("–"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Overload for pre-formatted string values
    private func validatedRow(_ label: String, value: String, warn: Bool) -> some View {
        LabeledContent(L10n.tr(label)) {
            Text(L10n.tr(value))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(warn ? .orange : .primary)
                .textSelection(.enabled)
        }
    }
}
