import Foundation
import Testing
@testable import OpenDente

@Suite("Helper status and official metadata")
@MainActor
struct HelperStatusMonitorTests {
    @Test func versionComparisonIsNumericAndRejectsUnknownStrings() throws {
        #expect(try #require(HelperVersion("1.10.0")) > #require(HelperVersion("1.4.0")))
        #expect(HelperVersion("1.4") == HelperVersion("1.4.0"))
        #expect(HelperVersion("unknown") == nil)
        #expect(HelperVersion("1.4.0-beta") == nil)
        #expect(HelperVersion("1..4") == nil)
        #expect(metadata.supports("1.4.0"))
        #expect(!metadata.supports("1.3.0"))
        #expect(!metadata.supports("2.0.0"))
    }

    @Test func enabledRegistrationDoesNotImplyRespondingOrCurrentVersion() async {
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { $0("") })
        monitor.refresh()
        await helperStatusDrain()
        #expect(monitor.snapshot.registration == .enabled)
        #expect(monitor.snapshot.connection == .notResponding)
        #expect(monitor.snapshot.activeVersion == nil)
        #expect(monitor.snapshot.compatibility == .unknown)
        #expect(monitor.latest == .unchecked)
        monitor.stop()
    }

    @Test func runningVersionIsReadAndComparedWithIncludedContract() async {
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { $0("1.4.0") })
        monitor.refresh()
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == "1.4.0")
        #expect(monitor.snapshot.connection == .responding)
        #expect(monitor.snapshot.compatibility == .compatible)
        #expect(monitor.latest == .unchecked) // Local compatibility cannot prove the latest published release.
        monitor.stop()
    }

    @Test func olderHelperIsFlaggedForThisApp() async {
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { $0("1.3.0") })
        monitor.refresh()
        await helperStatusDrain()
        #expect(monitor.snapshot.connection == .responding)
        #expect(monitor.snapshot.compatibility == .needsUpdate)
        monitor.stop()
    }

    @Test func timeoutClearsVersionAndLateReplyCannotRestoreIt() async throws {
        let probe = HelperVersionProbeBox()
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
            versionProbe: { probe.capture($0) }, timeout: .milliseconds(30))
        monitor.refresh()
        probe.reply(index: 0, version: "1.4.0")
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == "1.4.0")
        monitor.refresh()
        try await Task.sleep(for: .milliseconds(75))
        #expect(monitor.snapshot.connection == .notResponding)
        #expect(monitor.snapshot.activeVersion == nil)
        #expect(monitor.snapshot.failureCode == "timeout")
        probe.reply(index: 1, version: "1.4.0")
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == nil)
        monitor.stop()
    }

    @Test func connectionLossImmediatelyClearsVersionAndRejectsOldHandshake() async {
        let probe = HelperVersionProbeBox()
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { probe.capture($0) })
        monitor.refresh()
        probe.reply(index: 0, version: "1.4.0")
        await helperStatusDrain()
        monitor.refresh()
        monitor.connectionLost()
        #expect(monitor.snapshot.activeVersion == nil)
        #expect(monitor.snapshot.compatibility == .unknown)
        probe.reply(index: 1, version: "1.4.0")
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == nil)
        monitor.refresh()
        probe.reply(index: 2, version: "1.4.0")
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == "1.4.0")
        #expect(monitor.snapshot.connection == .responding)
        monitor.stop()
    }

    @Test func restoredConnectionReplacesAnyPendingProbe() async {
        let probe = HelperVersionProbeBox()
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { probe.capture($0) })
        monitor.refresh()
        monitor.connectionRestored()
        probe.reply(index: 1, version: "1.4.0")
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == "1.4.0")
        probe.reply(index: 0, version: "1.3.0")
        await helperStatusDrain()
        #expect(monitor.snapshot.activeVersion == "1.4.0")
        #expect(monitor.snapshot.compatibility == .compatible)
        monitor.stop()
    }

    @Test func noPublishedReleaseIsDifferentFromUpToDate() async throws {
        let lookup = HelperReleaseLookup(request: { _ in (Data(), 404) })
        #expect(try await lookup.latest() == .noRelease)
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { $0("1.4.0") }, releaseLookup: lookup)
        monitor.checkForUpdates()
        await helperStatusWait { monitor.latest != .checking }
        #expect(monitor.latest == .noRelease)
        #expect(monitor.latestCheckedAt != nil)
        monitor.stop()
    }

    @Test func tagWithoutHelperMetadataIsNotVerifiable() async throws {
        let lookup = HelperReleaseLookup(request: { _ in (releaseData(assets: "[]"), 200) })
        #expect(try await lookup.latest() == .noMetadata)
    }

    @Test func malformedHelperMetadataIsNotVerifiable() async throws {
        let lookup = HelperReleaseLookup(request: { request in
            if request.url?.host == "api.github.com" { return (releaseData(assets: officialAssets), 200) }
            return (Data("{\"helperVersion\":\"latest\"}".utf8), 200)
        })
        #expect(try await lookup.latest() == .noMetadata)
    }

    @Test func offlineLookupDoesNotClaimLatestVersion() async {
        let lookup = HelperReleaseLookup(request: { _ in throw URLError(.notConnectedToInternet) })
        let monitor = HelperStatusMonitor(bundledMetadata: metadata, registration: { .enabled },
                                          versionProbe: { $0("1.4.0") }, releaseLookup: lookup)
        monitor.checkForUpdates()
        await helperStatusWait { monitor.latest != .checking }
        if case .unavailable = monitor.latest { #expect(monitor.latestCheckedAt != nil) }
        else { Issue.record("Offline release lookup must be unavailable, never up to date") }
        monitor.stop()
    }

    @Test func verifiedOfficialMetadataContainsExplicitHelperVersion() async throws {
        let payload = try JSONEncoder().encode(metadata)
        let lookup = HelperReleaseLookup(request: { request in
            request.url?.host == "api.github.com" ? (releaseData(assets: officialAssets), 200) : (payload, 200)
        })
        let result = try await lookup.latest()
        guard case .verified(let value, let url) = result else { Issue.record("Expected validated release metadata"); return }
        #expect(value.helperVersion == "1.4.0")
        #expect(url.host == "github.com")
        #expect(value.supports("1.4.0"))
    }

    @Test func releaseAssetsOutsideOfficialRepositoryAreRejected() async throws {
        let lookup = HelperReleaseLookup(request: { _ in
            (releaseData(assets: "[{\"name\":\"opendente-release.json\",\"browser_download_url\":\"https://example.com/helper.json\"}]"), 200)
        })
        await #expect(throws: HelperReleaseLookupError.self) { try await lookup.latest() }
    }

    private var metadata: HelperReleaseMetadata {
        .init(schemaVersion: 1, appVersion: "0.2.0", helperVersion: "1.4.0",
              minimumCompatibleHelperVersion: "1.4.0", maximumExclusiveCompatibleHelperVersion: "2.0.0")
    }
}

private let officialAssets = "[{\"name\":\"opendente-release.json\",\"browser_download_url\":\"https://github.com/killerk3emstar/OpenDente/releases/download/v0.2.0/opendente-release.json\"}]"
private func releaseData(assets: String) -> Data {
    Data("{\"html_url\":\"https://github.com/killerk3emstar/OpenDente/releases/tag/v0.2.0\",\"draft\":false,\"prerelease\":false,\"assets\":\(assets)}".utf8)
}
private func helperStatusDrain() async {
    for _ in 0..<15 { await Task.yield() }
}
@MainActor
private func helperStatusWait(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for injected helper status operation")
}

private final class HelperVersionProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (String) -> Void] = []
    func capture(_ callback: @escaping @Sendable (String) -> Void) { lock.withLock { callbacks.append(callback) } }
    func reply(index: Int, version: String) {
        let callback = lock.withLock { callbacks[index] }
        callback(version)
    }
}
