import SwiftUI

struct HelperStatusPanel: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var monitor = HelperStatusMonitor.shared

    var body: some View {
        GroupBox(L10n.tr("Privileged Helper")) {
            VStack(alignment: .leading, spacing: 9) {
                row("Registration", registrationLabel, color: monitor.snapshot.registration == .enabled ? .green : .orange)
                row("Connection", connectionLabel, color: monitor.snapshot.connection == .responding ? .green : .orange)
                row("Running Version", monitor.snapshot.activeVersion ?? "—")
                row("Included Version", monitor.bundledMetadata.helperVersion)
                row("Compatible with This App", compatibilityLabel,
                    color: monitor.snapshot.compatibility == .compatible ? .green : .orange)
                Divider()
                row("Latest Official Release", releaseLabel, color: releaseColor)
                if let checked = monitor.snapshot.checkedAt {
                    row("Last Connection Check", L10n.date(checked, includeTime: true))
                }
                if let checked = monitor.latestCheckedAt {
                    row("Last Release Check", L10n.date(checked, includeTime: true))
                }
                Text(L10n.tr("Enabled means registered with macOS. A responding helper and a compatible running version are verified separately. The native charge limit works without this helper."))
                    .font(.caption).foregroundStyle(.secondary)
                if monitor.snapshot.failureCode == "timeout" {
                    Text(L10n.tr("The helper did not reply within 5 seconds. Its running version is unknown."))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(L10n.tr("Check Connection")) { monitor.refresh() }.disabled(monitor.isRefreshing)
                    Button(L10n.tr("Check for Updates")) { monitor.checkForUpdates() }
                        .disabled(monitor.latest == .checking)
                    if monitor.isRefreshing || monitor.latest == .checking { ProgressView().controlSize(.small) }
                    Spacer()
                    if case .verified(_, let url) = monitor.latest { Link(L10n.tr("Official Release"), destination: url) }
                }.font(.caption)
            }.padding(4)
        }.task { monitor.refresh() }
    }
    private func row(_ title: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.tr(title)).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
    private var registrationLabel: String {
        switch monitor.snapshot.registration {
        case .enabled: L10n.tr("Enabled")
        case .notRegistered: L10n.tr("Not Registered")
        case .requiresApproval: L10n.tr("Requires Approval")
        case .notFound: L10n.tr("Not Found in Bundle")
        case .unknown: L10n.tr("Unknown")
        }
    }
    private var connectionLabel: String {
        if monitor.isRefreshing { return L10n.tr("Checking…") }
        return switch monitor.snapshot.connection {
        case .unknown: L10n.tr("Not Checked")
        case .responding: L10n.tr("Responding")
        case .notResponding: L10n.tr("Not Responding")
        }
    }
    private var compatibilityLabel: String {
        switch monitor.snapshot.compatibility {
        case .unknown: L10n.tr("Not Verifiable")
        case .compatible:
            monitor.snapshot.activeVersion == monitor.bundledMetadata.helperVersion
                ? L10n.tr("Up to Date for This App") : L10n.tr("Compatible")
        case .needsUpdate: L10n.tr("Update Required for This App")
        case .incompatible: L10n.tr("Incompatible")
        }
    }
    private var releaseLabel: String {
        switch monitor.latest {
        case .unchecked: return L10n.tr("Not Checked")
        case .checking: return L10n.tr("Checking…")
        case .noRelease: return L10n.tr("No Official Release Published")
        case .noMetadata: return L10n.tr("Helper Version Not Published · Not Verifiable")
        case .unavailable: return L10n.tr("Release Check Unavailable · Not Verifiable")
        case .verified(let metadata, _):
            guard let current = monitor.snapshot.activeVersion.flatMap(HelperVersion.init),
                  let latest = HelperVersion(metadata.helperVersion) else {
                return L10n.format("Published: %@ · Running Version Unknown", metadata.helperVersion)
            }
            if current == latest { return L10n.format("Up to Date · %@", metadata.helperVersion) }
            if current > latest { return L10n.format("Newer than Latest Release · %@", metadata.helperVersion) }
            return L10n.format("Update Available · %@", metadata.helperVersion)
        }
    }
    private var releaseColor: Color {
        guard case .verified(let metadata, _) = monitor.latest,
              let active = monitor.snapshot.activeVersion.flatMap(HelperVersion.init),
              let published = HelperVersion(metadata.helperVersion) else { return .secondary }
        return active >= published ? .green : .orange
    }
}
