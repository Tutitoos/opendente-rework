import AppKit
import Combine
import Foundation
import ServiceManagement

struct HelperVersion: Equatable, Comparable, Sendable {
    let components: [Int]
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (0...999_999).contains($0) }) else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct HelperReleaseMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let helperVersion: String
    let minimumCompatibleHelperVersion: String
    let maximumExclusiveCompatibleHelperVersion: String

    var isValid: Bool {
        guard schemaVersion == 1, HelperVersion(appVersion) != nil,
              let included = HelperVersion(helperVersion), let min = HelperVersion(minimumCompatibleHelperVersion),
              let max = HelperVersion(maximumExclusiveCompatibleHelperVersion) else { return false }
        return min <= included && included < max
    }
    func supports(_ version: String) -> Bool {
        guard isValid, let version = HelperVersion(version), let min = HelperVersion(minimumCompatibleHelperVersion),
              let max = HelperVersion(maximumExclusiveCompatibleHelperVersion) else { return false }
        return min <= version && version < max
    }
    static var bundled: Self {
        if let url = Bundle.main.url(forResource: "opendente-release", withExtension: "json"),
           let data = try? Data(contentsOf: url), let metadata = try? JSONDecoder().decode(Self.self, from: data),
           metadata.isValid, metadata.helperVersion == HelperConstants.helperVersion { return metadata }
        // This fallback reports the compiled requirement, never a guessed remote release.
        return .init(schemaVersion: 1, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0",
                     helperVersion: HelperConstants.helperVersion,
                     minimumCompatibleHelperVersion: HelperConstants.helperVersion,
                     maximumExclusiveCompatibleHelperVersion: "2.0.0")
    }
}

enum HelperRegistrationState: String, Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound, unknown
    @MainActor init(_ status: SMAppService.Status) {
        self = switch status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
}
enum HelperConnectionState: String, Equatable, Sendable { case unknown, responding, notResponding }
enum HelperAppCompatibility: String, Equatable, Sendable { case unknown, compatible, needsUpdate, incompatible }

struct HelperStatusSnapshot: Equatable, Sendable {
    var registration: HelperRegistrationState = .unknown
    var connection: HelperConnectionState = .unknown
    var activeVersion: String?
    var compatibility: HelperAppCompatibility = .unknown
    var checkedAt: Date?
    var failureCode: String?
}

enum HelperLatestReleaseStatus: Equatable, Sendable {
    case unchecked, checking, noRelease, noMetadata, unavailable(String)
    case verified(metadata: HelperReleaseMetadata, releaseURL: URL)
}

enum HelperReleaseLookupError: Error {
    case response(Int), malformed, invalidAsset
}

/// Reads only official release metadata. A GitHub tag alone cannot establish the helper version.
struct HelperReleaseLookup: Sendable {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, Int)
    let request: Request
    init(request: @escaping Request = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }) { self.request = request }

    func latest() async throws -> HelperLatestReleaseStatus {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String }
            let html_url: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let api = URL(string: "https://api.github.com/repos/killerk3emstar/OpenDente/releases/latest")!
        var apiRequest = URLRequest(url: api, timeoutInterval: 12)
        apiRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        apiRequest.setValue("OpenDente-Helper-Version-Check", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await request(apiRequest)
        if status == 404 { return .noRelease }
        guard status == 200 else { throw HelperReleaseLookupError.response(status) }
        guard data.count <= 1_024 * 1_024, let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let releaseURL = URL(string: release.html_url), Self.officialURL(releaseURL) else {
            throw HelperReleaseLookupError.malformed
        }
        guard let asset = release.assets.first(where: { $0.name == "opendente-release.json" }) else { return .noMetadata }
        guard let assetURL = URL(string: asset.browser_download_url), Self.officialURL(assetURL) else {
            throw HelperReleaseLookupError.invalidAsset
        }
        let (metadataData, metadataStatus) = try await request(URLRequest(url: assetURL, timeoutInterval: 12))
        guard metadataStatus == 200 else { throw HelperReleaseLookupError.response(metadataStatus) }
        guard metadataData.count <= 64 * 1_024,
              let metadata = try? JSONDecoder().decode(HelperReleaseMetadata.self, from: metadataData), metadata.isValid else {
            return .noMetadata
        }
        return .verified(metadata: metadata, releaseURL: releaseURL)
    }
    private static func officialURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.path.lowercased().hasPrefix("/killerk3emstar/opendente/releases/")
    }
}

/// Registration is independent of whether the already registered XPC service responds.
/// Constructing this model never registers, unregisters, launches or rewrites a helper.
@MainActor
final class HelperStatusMonitor: ObservableObject {
    static let shared = HelperStatusMonitor()
    @Published private(set) var snapshot = HelperStatusSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var latest: HelperLatestReleaseStatus = .unchecked
    @Published private(set) var latestCheckedAt: Date?
    let events = PassthroughSubject<LocalActivityEvent, Never>()
    let bundledMetadata: HelperReleaseMetadata

    private let registration: @MainActor () -> HelperRegistrationState
    private let versionProbe: @Sendable (@escaping @Sendable (String) -> Void) -> Void
    private let timeout: Duration
    private let releaseLookup: HelperReleaseLookup
    private var requestID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers = Set<AnyCancellable>()

    init(bundledMetadata: HelperReleaseMetadata = .bundled,
         registration: @escaping @MainActor () -> HelperRegistrationState = { HelperRegistrationState(HelperInstaller.status) },
         versionProbe: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void = { HelperClient.shared.getVersion(completion: $0) },
         timeout: Duration = .seconds(5), releaseLookup: HelperReleaseLookup = .init()) {
        self.bundledMetadata = bundledMetadata
        self.registration = registration
        self.versionProbe = versionProbe
        self.timeout = timeout
        self.releaseLookup = releaseLookup
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: .openDenteHelperConnectionLost)
            .sink { [weak self] _ in Task { @MainActor in self?.connectionLost() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: .openDenteHelperConnectionRestored)
            .sink { [weak self] _ in Task { @MainActor in self?.connectionRestored() } }.store(in: &observers)
        refresh()
        checkForUpdates()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
        updateTask?.cancel()
        updateTask = nil
        requestID = nil
        isRefreshing = false
        snapshot.activeVersion = nil
        snapshot.compatibility = .unknown
        snapshot.connection = .unknown
        if latest == .checking { latest = .unchecked }
    }

    func connectionRestored() {
        requestID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isRefreshing = false
        refresh()
    }

    func connectionLost() {
        requestID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isRefreshing = false
        let hadResponse = snapshot.connection == .responding || snapshot.activeVersion != nil
        snapshot.activeVersion = nil
        snapshot.connection = .notResponding
        snapshot.compatibility = .unknown
        snapshot.failureCode = "connectionLost"
        snapshot.checkedAt = Date()
        if hadResponse {
            events.send(.init(category: .helper, severity: .warning, code: "helper.unavailable",
                              values: ["reason": "connectionLost"]))
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let id = UUID()
        requestID = id
        let registered = registration()
        if snapshot.registration != registered {
            snapshot.registration = registered
            events.send(.init(category: .helper, code: "helper.registration", values: ["state": registered.rawValue]))
        }
        timeoutTask?.cancel()
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(id: id, version: nil, failure: "timeout")
        }
        versionProbe { [weak self] version in
            Task { @MainActor [weak self] in
                self?.finish(id: id, version: HelperVersion(version) == nil ? nil : version,
                             failure: version.isEmpty ? "connectionUnavailable" : "invalidVersion")
            }
        }
    }

    private func finish(id: UUID, version: String?, failure: String) {
        finish(id: id, version: version, failure: version == nil ? Optional(failure) : nil)
    }
    private func finish(id: UUID, version: String?, failure: String?) {
        guard requestID == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        requestID = nil
        isRefreshing = false
        let old = snapshot
        snapshot.activeVersion = version // Clear stale active versions on any failure or timeout.
        snapshot.connection = version == nil ? .notResponding : .responding
        snapshot.checkedAt = Date()
        snapshot.failureCode = failure
        if let version {
            if bundledMetadata.supports(version) { snapshot.compatibility = .compatible }
            else if let active = HelperVersion(version), let included = HelperVersion(bundledMetadata.helperVersion), active < included {
                snapshot.compatibility = .needsUpdate
            } else { snapshot.compatibility = .incompatible }
        } else { snapshot.compatibility = .unknown }
        if old.connection != snapshot.connection || old.activeVersion != version || old.failureCode != failure {
            events.send(.init(category: .helper, severity: version == nil ? .warning : .info,
                              code: version == nil ? "helper.unavailable" : old.connection == .notResponding ? "helper.reconnected" : "helper.responding",
                              values: ["version": version ?? "", "reason": failure ?? "", "compatibility": snapshot.compatibility.rawValue]))
        }
    }

    func checkForUpdates() {
        guard updateTask == nil else { return }
        latest = .checking
        let lookup = releaseLookup
        updateTask = Task { [weak self] in
            let result: HelperLatestReleaseStatus
            do { result = try await lookup.latest() }
            catch is CancellationError { return }
            catch { result = .unavailable(String(describing: error)) }
            guard let self, !Task.isCancelled else { return }
            self.latest = result
            self.latestCheckedAt = Date()
            self.updateTask = nil
            self.events.send(.init(category: .helper, code: "helper.releaseChecked",
                values: ["result": Self.releaseCode(result)]))
        }
    }
    private static func releaseCode(_ value: HelperLatestReleaseStatus) -> String {
        switch value {
        case .unchecked: "unchecked"
        case .checking: "checking"
        case .noRelease: "noRelease"
        case .noMetadata: "noMetadata"
        case .unavailable: "unavailable"
        case .verified(let metadata, _): metadata.helperVersion
        }
    }
}
