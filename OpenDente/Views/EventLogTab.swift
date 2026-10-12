import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension ActivityCategory {
    var title: String {
        switch self {
        case .charging: L10n.tr("Charging")
        case .nativePolicy: L10n.tr("macOS Charging Policy")
        case .monthlyCharge: L10n.tr("Monthly Full Charge")
        case .helper: L10n.tr("Helper")
        case .application: L10n.tr("Application")
        }
    }
}
@MainActor
extension ActivitySeverity {
    var title: String {
        switch self { case .info: L10n.tr("Information"); case .warning: L10n.tr("Warning"); case .error: L10n.tr("Error") }
    }
    var color: Color {
        switch self { case .info: .secondary; case .warning: .orange; case .error: .red }
    }
}

@MainActor
extension LocalActivityEvent {
    /// Messages are rendered in the current language; persisted codes remain stable.
    var summary: String { localizedSummary(language: LanguageManager.shared.language) }

    func localizedSummary(language: AppLanguage, bundle: Bundle = .main) -> String {
        func tr(_ key: String) -> String { L10n.localized(key, language: language, bundle: bundle) }
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: tr(key), locale: language.locale, arguments: args)
        }
        let limit = values["limit"] ?? "—"
        let enabled = tr(values["enabled"] == "true" ? "Enabled" : "Disabled")
        switch code {
        case "application.started": return tr("OpenDente Started")
        case "application.stopped": return tr("OpenDente Stopped")
        case "application.sleep": return tr("Mac Entered Sleep")
        case "application.wake": return tr("Mac Woke from Sleep")
        case "native.limitRequested": return format("Charge limit requested: %@%%", limit)
        case "native.limitConfirmed": return values["external"] == "true"
            ? format("External charge limit observed: %@%%", limit)
            : format("Charge limit confirmed: %@%%", limit)
        case "native.optimizedRequested": return format("Optimized charging requested: %@", enabled)
        case "native.optimizedConfirmed": return values["external"] == "true"
            ? format("External optimized charging observed: %@", enabled)
            : format("Optimized charging confirmed: %@", enabled)
        case "native.operationFailed":
            let operation = switch values["operation"] {
            case "chargeLimit": tr("Charge Limit")
            case "optimizedCharging": tr("Optimized Battery Charging")
            default: values["operation"] ?? "—"
            }
            return format("Charging policy operation failed: %@", operation)
        case "monthly.scheduled": return tr("Monthly Full Charge Scheduled")
        case "monthly.started": return tr("Monthly Full Charge Started")
        case "monthly.completed": return tr("Monthly Full Charge Completed; Usual Limit Restored")
        case "monthly.cancelled": return tr("Monthly Full Charge Cancelled")
        case "monthly.failed": return tr("Monthly Full Charge Failed")
        case "monthly.pending": return tr("Monthly Full Charge Pending")
        case "helper.registration": return format("Helper registration: %@", tr(Self.registrationKey(values["state"] ?? "")))
        case "helper.responding": return format("Helper responded · Version %@", values["version"] ?? "—")
        case "helper.reconnected": return format("Helper reconnected · Version %@", values["version"] ?? "—")
        case "helper.unavailable": return tr("Helper Not Responding")
        case "helper.releaseChecked": return tr("Official Helper Release Check Finished")
        case "charging.modeObserved":
            let mode = values["mode"].flatMap(ChargingMode.init(rawValue:))
            return format("Charging mode observed: %@", mode.map { tr($0.displayName) } ?? "—")
        case "charging.telemetryObserved":
            if values["valid"] != "true" { return tr("Battery Reading Unavailable") }
            if values["pluggedIn"] != "true" { return tr("Running on Battery") }
            if values["charging"] == "true" { return tr("Charging Observed") }
            if values["systemLimitActive"] == "true" { return tr("Native Charge Limit Pause Observed") }
            return tr("Charging Paused · Cause Not Established")
        default: return format("Event: %@", code)
        }
    }

    var explanation: String? { localizedExplanation(language: LanguageManager.shared.language) }

    func localizedExplanation(language: AppLanguage, bundle: Bundle = .main) -> String? {
        func tr(_ key: String) -> String { L10n.localized(key, language: language, bundle: bundle) }
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: tr(key), locale: language.locale, arguments: args)
        }
        func boolean(_ key: String) -> String {
            switch values[key] { case "true": tr("Enabled"); case "false": tr("Disabled"); default: tr("Unknown") }
        }
        if code == "monthly.pending" {
            return tr(values["reason"] == "power" ? "Waiting for Power Adapter"
                      : "Waiting for Native Full-charge Override to End")
        }
        let detail = values["detail"].map(tr) ?? "—"
        switch values["failureCode"] {
        case "nativeUnavailable": return tr("The native macOS charge limit is unavailable.")
        case "nativeInvalidState": return format("The native charge limit returned invalid data: %@.", detail)
        case "nativeUnsupportedLimit":
            guard let limit = values["limit"].flatMap(Int.init) else { return tr("Unknown") }
            return format("macOS does not support a native charge limit of %d%%.", limit)
        case "nativeVerificationFailed":
            guard let requested = values["requested"].flatMap(Int.init), let actual = values["actual"].flatMap(Int.init) else { return tr("Unknown") }
            return format("macOS did not confirm the requested %d%% limit (effective limit: %d%%, %@).",
                          requested, actual, boolean("enabled"))
        case "optimizedUnavailable": return tr("Native optimized battery charging is unavailable.")
        case "optimizedVerificationFailed":
            return format("macOS did not confirm optimized battery charging (requested: %@, actual: %@).",
                          boolean("requested"), boolean("actual"))
        case "temporaryUnavailable", "monthlyUnavailable": return tr("Native temporary full charging is unavailable.")
        case "temporaryVerificationFailed": return format("macOS did not confirm temporary full charging: %@.", detail)
        case "monthlyInvalidNextDate": return tr("Choose a valid next full-charge date.")
        case "monthlyPolicyChangedExternally": return tr("Monthly charging was cancelled because the charging policy changed.")
        case "monthlyRestoreFailed": return format("The previous charging policy could not be restored: %@", detail)
        case "monthlyInterrupted": return tr("Monthly charging was interrupted; the previous policy has been restored.")
        case "chargingPolicyError": return detail
        default: return nil
        }
    }
    private static func registrationKey(_ value: String) -> String {
        switch HelperRegistrationState(rawValue: value) {
        case .enabled: "Enabled"
        case .notRegistered: "Not Registered"
        case .requiresApproval: "Requires Approval"
        case .notFound: "Not Found in Bundle"
        case .unknown, nil: "Unknown"
        }
    }
}

struct EventLogTab: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var recorder = LocalActivityRecorder.shared
    @ObservedObject private var preferences = LocalActivityPreferences.shared
    @State private var events: [LocalActivityEvent] = []
    @State private var category: ActivityCategory?
    @State private var severity: ActivitySeverity?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var damaged = 0
    @State private var showClearConfirmation = false

    private var filtered: [LocalActivityEvent] {
        events.filter { event in
            event.matches(category: category, severity: severity, search: "")
                && (search.isEmpty || event.matches(category: nil, severity: nil, search: search)
                    || event.summary.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Local Event Log")).font(.title3.bold())
            Text(L10n.tr("Changes, observed charging states and failures. Repeated identical states are omitted. Events are stored only on this Mac."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.tr("Search Events"), text: $search)
                Picker(L10n.tr("Category"), selection: $category) {
                    Text(L10n.tr("All Categories")).tag(ActivityCategory?.none)
                    ForEach(ActivityCategory.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden()
                Picker(L10n.tr("Severity"), selection: $severity) {
                    Text(L10n.tr("All Severities")).tag(ActivitySeverity?.none)
                    ForEach(ActivitySeverity.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden()
            }
            if loading { ProgressView().controlSize(.small) }
            if filtered.isEmpty && !loading {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.title2)
                    Text(L10n.tr(events.isEmpty ? "No Events Recorded" : "No Matching Events"))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(filtered) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(event.summary).font(.callout.weight(.medium))
                                    Spacer(minLength: 4)
                                    Text(L10n.date(event.timestamp, includeTime: true)).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(event.category.title)
                                    Text("·")
                                    Text(event.severity.title).foregroundStyle(event.severity.color)
                                    Spacer()
                                    Text(event.code).font(.system(.caption2, design: .monospaced))
                                }.font(.caption).foregroundStyle(.secondary)
                                if let explanation = event.explanation {
                                    Text(explanation).font(.caption).foregroundStyle(event.severity.color)
                                }
                                if !event.values.isEmpty {
                                    DisclosureGroup(L10n.tr("Technical Details")) {
                                        Text(event.values.keys.sorted().compactMap { key in
                                            guard let value = event.values[key], !value.isEmpty else { return nil }
                                            return "\(key): \(value)"
                                        }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }.font(.caption2)
                                }
                                Divider()
                            }.accessibilityElement(children: .combine)
                        }
                    }.padding(.trailing, 8)
                }
            }
            if damaged > 0 {
                Text(L10n.format(damaged == 1
                                ? "%d damaged record was skipped. Valid records remain available."
                                : "%d damaged records were skipped. Valid records remain available.", damaged))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = error ?? recorder.storageError { Text(L10n.tr(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Picker(L10n.tr("Retention"), selection: $preferences.eventRetentionDays) {
                    ForEach([30, 90, 365], id: \.self) { Text(L10n.format("%d days", $0)).tag($0) }
                }.frame(maxWidth: 185)
                Spacer()
                Text(L10n.format(events.count == 1 ? "Showing the latest %d event" : "Showing the latest %d events", events.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.tr("Refresh")) { Task { await reload() } }
                Button(L10n.tr("Export Events…")) { export() }
                Spacer()
                Button(L10n.tr("Clear Events…"), role: .destructive) { showClearConfirmation = true }
            }.font(.caption)
        }.padding(20)
        .task { await reload() }
        .onChange(of: recorder.revision) { _, _ in Task { await reload() } }
        .confirmationDialog(L10n.tr("Clear all local events?"), isPresented: $showClearConfirmation) {
            Button(L10n.tr("Clear Events"), role: .destructive) {
                Task {
                    do { try await recorder.clearEvents(); await reload() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button(L10n.tr("Cancel"), role: .cancel) { }
        }
    }

    private func reload() async {
        loading = true
        do {
            let snapshot = try await recorder.store.events()
            events = snapshot.events
            damaged = snapshot.damagedRecords
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func export() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Export Local Events")
        panel.prompt = L10n.tr("Export")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenDente-events.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { let data = try await recorder.store.exportEvents(); try data.write(to: url, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }
}
