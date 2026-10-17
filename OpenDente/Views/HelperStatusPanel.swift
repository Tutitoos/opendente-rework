import SwiftUI

struct HelperStatusPanel: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var monitor = HelperStatusMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: connectionSymbol)
                    .font(.title2)
                    .foregroundStyle(connectionColor)
                    .frame(width: 24)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(connectionLabel)
                        .font(.headline)
                    Text(compatibilityLabel)
                        .font(.callout)
                        .foregroundStyle(compatibilityColor)
                        .fixedSize(horizontal: false, vertical: true)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let version = monitor.snapshot.activeVersion {
                    Text(version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .accessibilityLabel(L10n.tr("Running Version") + ": " + version)
                }
            }

            if monitor.snapshot.failureCode == "timeout" {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(L10n.tr("The helper did not reply within 5 seconds. Its running version is unknown."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Divider()

            LabeledContent(L10n.tr("Registration"), value: registrationLabel)
                .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Latest Official Release"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(releaseLabel)
                    .font(.body)
                    .foregroundStyle(releaseColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if case .verified(_, let url) = monitor.latest {
                    Link(L10n.tr("Official Release"), destination: url)
                        .font(.callout)
                }
            }

            HStack(spacing: 10) {
                Button(L10n.tr("Check Connection")) { monitor.checkConnection() }
                    .disabled(monitor.isRefreshing)
                Button(L10n.tr("Check for Updates")) { monitor.checkForUpdates() }
                    .disabled(monitor.latest == .checking)
                if monitor.isRefreshing || monitor.latest == .checking {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.regular)

            DisclosureGroup(L10n.tr("Technical Details")) {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("Included Version", monitor.bundledMetadata.helperVersion)
                    if let checked = monitor.snapshot.checkedAt {
                        detailRow("Last Connection Check", L10n.date(checked, includeTime: true))
                    }
                    if let checked = monitor.latestCheckedAt {
                        detailRow("Last Release Check", L10n.date(checked, includeTime: true))
                    }
                    Text(L10n.tr("Enabled means registered with macOS. A responding helper and a compatible running version are verified separately. The native charge limit works without this helper."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { monitor.refresh() }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(L10n.tr(title)) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
    private var connectionSymbol: String {
        if monitor.isRefreshing { return "arrow.triangle.2.circlepath" }
        return switch monitor.snapshot.connection {
        case .unknown: "questionmark.circle"
        case .responding: "checkmark.circle.fill"
        case .notResponding: "exclamationmark.circle.fill"
        }
    }
    private var connectionColor: Color {
        if monitor.isRefreshing { return .secondary }
        return switch monitor.snapshot.connection {
        case .unknown: .secondary
        case .responding: .green
        case .notResponding: .red
        }
    }
    private var compatibilityColor: Color {
        monitor.snapshot.compatibility == .compatible ? .green : .orange
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
