import Foundation
import IOKit
import Security
import Testing

private enum FixtureError: Error { case injected }

private final class MemoryState: HelperStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: HelperState.ChargingState?
    private var history: [HelperState.ChargingState] = []
    private var failRead = false
    private var failWrite = false
    init(_ value: HelperState.ChargingState? = nil, failRead: Bool = false, failWrite: Bool = false) {
        self.value = value; self.failRead = failRead; self.failWrite = failWrite
    }
    var state: HelperState.ChargingState? { lock.withLock { value } }
    var writes: [HelperState.ChargingState] { lock.withLock { history } }
    func read() throws -> HelperState.ChargingState? {
        try lock.withLock { if failRead { throw FixtureError.injected }; return value }
    }
    func write(_ state: HelperState.ChargingState) throws {
        try lock.withLock {
            history.append(state)
            if failWrite { throw FixtureError.injected }
            value = state
        }
    }
}

private final class MockWatchdog: HelperWatchdog, @unchecked Sendable {
    private let lock = NSLock()
    private var resumeCount = 0
    private var suspendCount = 0
    var resumes: Int { lock.withLock { resumeCount } }
    var suspends: Int { lock.withLock { suspendCount } }
    func receivedHeartbeat() {}
    func suspend() { lock.withLock { suspendCount += 1 } }
    func resume() { lock.withLock { resumeCount += 1 } }
}

private final class MockSMC: HelperSMC, @unchecked Sendable {
    struct Write: Equatable { let key: String; let bytes: [UInt8] }
    private let lock = NSLock()
    private var values: [String: [UInt8]]
    private var history: [Write] = []
    private let failingKeys: Set<String>
    private let failingNonzeroKeys: Set<String>
    private let ignoredNonzeroKeys: Set<String>
    private let state: MemoryState?
    private var unmarkedMutation = false
    private var openFailures: Int
    private var isOpen = false
    private var metadataFailures: [String: Int]
    init(tahoe: Bool = false, discharge: Bool = true, led: Bool = true,
         failingKeys: Set<String> = [], failingNonzeroKeys: Set<String> = [],
         ignoredNonzeroKeys: Set<String> = [], state: MemoryState? = nil,
         openFailures: Int = 0, metadataFailures: [String: Int] = [:],
         inheritedDischarge: Bool = false) {
        values = tahoe ? ["CHTE": [inheritedDischarge ? 1 : 0, 0, 0, 0]]
                       : ["CH0B": [inheritedDischarge ? 2 : 0], "CH0C": [inheritedDischarge ? 2 : 0]]
        if discharge { values[tahoe ? "CHIE" : "CH0I"] = [inheritedDischarge ? (tahoe ? 8 : 1) : 0] }
        if led { values["ACLC"] = [0] }
        self.failingKeys = failingKeys; self.failingNonzeroKeys = failingNonzeroKeys
        self.ignoredNonzeroKeys = ignoredNonzeroKeys; self.state = state
        self.openFailures = openFailures; self.metadataFailures = metadataFailures
    }
    var writes: [Write] { lock.withLock { history } }
    var mutatedWithoutMarker: Bool { lock.withLock { unmarkedMutation } }
    func open() throws {
        try lock.withLock {
            if openFailures > 0 { openFailures -= 1; throw FixtureError.injected }
            isOpen = true
        }
    }
    func keyExists(_ key: String) -> Bool { lock.withLock { values[key] != nil } }
    func keyInfo(_ key: String) -> (type: String, size: UInt32)? {
        lock.withLock { values[key].map { ($0.count == 1 ? "ui8 " : "ui32", UInt32($0.count)) } }
    }
    func keyInfoChecked(_ key: String) throws -> (type: String, size: UInt32)? {
        try lock.withLock {
            guard isOpen else { throw FixtureError.injected }
            if (metadataFailures[key] ?? 0) > 0 {
                metadataFailures[key, default: 0] -= 1
                throw FixtureError.injected
            }
            return values[key].map { ($0.count == 1 ? "ui8 " : "ui32", UInt32($0.count)) }
        }
    }
    func readKeyOptional(_ key: String) -> SMCValue? {
        lock.withLock { isOpen ? values[key].map { SMCValue(key: key, dataSize: UInt32($0.count), dataType: "ui8 ", bytes: $0) } : nil }
    }
    func writeKey(_ key: String, bytes: [UInt8]) throws {
        try lock.withLock {
            history.append(Write(key: key, bytes: bytes))
            guard isOpen else { throw FixtureError.injected }
            if bytes.contains(where: { $0 != 0 }), let state, state.state != .inhibited { unmarkedMutation = true }
            if failingKeys.contains(key) || (bytes.first != 0 && failingNonzeroKeys.contains(key)) { throw FixtureError.injected }
            if bytes.first != 0 && ignoredNonzeroKeys.contains(key) { return }
            values[key] = bytes
        }
    }
}

private func reply(_ action: (@escaping (Bool, String?) -> Void) -> Void) -> (Bool, String?) {
    var result: (Bool, String?) = (false, "No reply")
    action { result = ($0, $1) }
    return result
}

@Suite("Helper safety without hardware")
struct HelperSafetyTests {
    @Test("F02: a failed discharge reset must not skip charging or LED restoration", arguments: [false, true])
    func independentReset(tahoe: Bool) {
        let state = MemoryState(.inhibited)
        let discharge = tahoe ? "CHIE" : "CH0I"
        let smc = MockSMC(tahoe: tahoe, failingKeys: [discharge], state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        let result = reply(delegate.resetToDefaults)
        #expect(!result.0)
        #expect(result.1 != nil)
        #expect(smc.writes.contains(.init(key: tahoe ? "CHTE" : "CH0B", bytes: tahoe ? [0, 0, 0, 0] : [0])))
        #expect(smc.writes.contains(.init(key: "ACLC", bytes: [0])))
        #expect(state.state == .inhibited)
        #expect(delegate.requiresRecovery)
    }

    @Test("F02: absent optional discharge key does not block a complete reset")
    func absentDischarge() {
        let state = MemoryState(.inhibited)
        let smc = MockSMC(discharge: false, state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(reply(delegate.resetToDefaults).0)
        #expect(!smc.writes.contains { $0.key == "CH0I" })
        #expect(state.state == .normal)
        #expect(!delegate.requiresRecovery)
    }

    @Test("F03: persistence must succeed before inhibition, discharge or LED writes", arguments: [0, 1, 2])
    func persistenceFailure(operation: Int) {
        let state = MemoryState(failWrite: true)
        let smc = MockSMC(state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        let result = reply { callback in
            switch operation {
            case 0: delegate.inhibitCharging(reply: callback)
            case 1: delegate.forceDischarge(enable: true, reply: callback)
            default: delegate.setMagSafeLED(color: 3, reply: callback)
            }
        }
        #expect(!result.0)
        #expect(smc.writes.isEmpty)
        #expect(delegate.requiresRecovery)
    }

    @Test("F03: every nondefault write has a durable marker", arguments: [false, true])
    func durableBeforeWrites(tahoe: Bool) {
        let state = MemoryState()
        let smc = MockSMC(tahoe: tahoe, state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(reply { delegate.forceDischarge(enable: true, reply: $0) }.0)
        #expect(!smc.mutatedWithoutMarker)
        #expect(state.state == .inhibited)
        #expect(delegate.requiresRecovery)
    }

    @Test("F03: a partial inhibition rolls back to defaults and reports failure")
    func partialRollback() {
        let state = MemoryState()
        let smc = MockSMC(failingNonzeroKeys: ["CH0C"], state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(!reply(delegate.inhibitCharging).0)
        #expect(smc.writes.contains(.init(key: "CH0B", bytes: [2])))
        #expect(smc.writes.contains(.init(key: "CH0B", bytes: [0])))
        #expect(smc.writes.contains(.init(key: "CH0I", bytes: [0])))
        #expect(state.writes == [.inhibited, .normal])
        #expect(!delegate.requiresRecovery)
    }

    @Test("F03: forced discharge is reversed when charging inhibition fails")
    func partialDischargeRollback() {
        let state = MemoryState()
        let smc = MockSMC(tahoe: true, failingNonzeroKeys: ["CHTE"], state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(!reply { delegate.forceDischarge(enable: true, reply: $0) }.0)
        #expect(smc.writes.contains(.init(key: "CHIE", bytes: [8])))
        #expect(smc.writes.contains(.init(key: "CHIE", bytes: [0])))
        #expect(state.state == .normal)
    }

    @Test("F03: a successful write call with failed readback is an operation failure")
    func failedReadback() {
        let state = MemoryState()
        let smc = MockSMC(ignoredNonzeroKeys: ["CH0B"], state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(!reply(delegate.inhibitCharging).0)
        #expect(state.state == .normal)
    }

    @Test("F03: unreadable recovery state triggers recovery")
    func unreadableState() {
        let state = MemoryState(failRead: true)
        let smc = MockSMC(state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(delegate.requiresRecovery)
        #expect(delegate.resetChargingDirect())
        #expect(!delegate.requiresRecovery)
    }

    @Test("F03/F05: sleep LED failure retains inhibition and its recovery marker")
    func sleepLEDFailure() {
        let state = MemoryState()
        let smc = MockSMC(failingNonzeroKeys: ["ACLC"], state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        let id = UUID()
        delegate.clientConnected(id)
        delegate.syncSleepSettings(stopChargingWhenSleeping: true, sleepLEDColor: 3) { #expect($0) }
        delegate.inhibitChargingOnSleep()
        #expect(smc.writes.contains(.init(key: "CH0B", bytes: [2])))
        #expect(state.state == .inhibited)
        #expect(delegate.requiresRecovery)
        #expect(!smc.mutatedWithoutMarker)
        delegate.clientDisconnected(id)
        #expect(state.state == .normal)
    }

    @Test("F05: only the last disconnect clears sleep policy and resets overrides")
    func clientLifetime() {
        let state = MemoryState()
        let smc = MockSMC(state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        let a = UUID(), b = UUID()
        delegate.syncSleepSettings(stopChargingWhenSleeping: true, sleepLEDColor: 0xFF) { #expect(!$0) }
        delegate.clientConnected(a); delegate.clientConnected(b)
        delegate.syncSleepSettings(stopChargingWhenSleeping: true, sleepLEDColor: 0xFF) { #expect($0) }
        delegate.clientDisconnected(a)
        delegate.inhibitChargingOnSleep()
        #expect(state.state == .inhibited)
        delegate.clientDisconnected(b)
        #expect(state.state == .normal)
        let count = smc.writes.count
        delegate.inhibitChargingOnSleep()
        #expect(smc.writes.count == count)
    }

    @Test("F05: explicit reset clears sleep policy while the client remains connected")
    func resetClearsSleepPolicy() {
        let state = MemoryState()
        let smc = MockSMC(state: state)
        let watchdog = MockWatchdog()
        let delegate = HelperDelegate(watchdog: watchdog, smc: smc, stateStore: state)
        delegate.clientConnected(UUID())
        delegate.syncSleepSettings(stopChargingWhenSleeping: true, sleepLEDColor: 0xFF) { #expect($0) }
        #expect(reply(delegate.resetToDefaults).0)
        let count = smc.writes.count
        delegate.inhibitChargingOnSleep()
        #expect(smc.writes.count == count)
        delegate.suspendWatchdog { #expect($0) }
        #expect(watchdog.suspends == 0)
        #expect(watchdog.resumes > 0)
    }

    @Test("F03: enabling charging does not erase discharge recovery state")
    func enablePreservesRecovery() {
        let state = MemoryState()
        let smc = MockSMC(state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(reply { delegate.forceDischarge(enable: true, reply: $0) }.0)
        #expect(reply(delegate.enableCharging).0)
        #expect(state.state == .inhibited)
        #expect(delegate.requiresRecovery)
    }

    @Test("Recovery retries a failed initial open instead of keeping API unknown")
    func retryFailedOpen() {
        let state = MemoryState(.inhibited)
        let smc = MockSMC(state: state, openFailures: 1)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(delegate.requiresRecovery)
        #expect(delegate.resetChargingDirect())
        #expect(smc.writes.contains(.init(key: "CH0I", bytes: [0])))
        #expect(smc.writes.contains(.init(key: "CH0B", bytes: [0])))
        #expect(state.state == .normal)
    }

    @Test("Heartbeats retry failed inherited-discharge recovery even with a live client", arguments: [false, true])
    func heartbeatRetriesInheritedRecovery(tahoe: Bool) {
        let state = MemoryState(.inhibited)
        let smc = MockSMC(tahoe: tahoe, state: state, openFailures: 3, inheritedDischarge: true)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        delegate.clientConnected(UUID())
        // Initialization and the startup restoration fail before the SMC opens.
        #expect(!delegate.resetChargingDirect())
        #expect(state.state == .inhibited && delegate.requiresRecovery)
        delegate.heartbeat { #expect($0) }
        #expect(state.state == .inhibited && delegate.requiresRecovery)
        // A healthy heartbeat is not proof that the inherited gate was reset.
        // The next one retries, probes the now-readable API, and restores it.
        delegate.heartbeat { #expect($0) }
        #expect(smc.readKeyOptional(tahoe ? "CHIE" : "CH0I")?.bytes == [0])
        #expect(smc.readKeyOptional(tahoe ? "CHTE" : "CH0B")?.bytes == (tahoe ? [0, 0, 0, 0] : [0]))
        #expect(state.state == .normal && !delegate.requiresRecovery)
        let restoredWrites = smc.writes
        delegate.heartbeat { #expect($0) }
        #expect(smc.writes == restoredWrites)
    }

    @Test("Healthy heartbeats preserve legitimate inhibited and discharging policies", arguments: [false, true])
    func heartbeatPreservesActivePolicy(discharge: Bool) {
        let state = MemoryState()
        let smc = MockSMC(tahoe: true, state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(reply { callback in
            if discharge { delegate.forceDischarge(enable: true, reply: callback) }
            else { delegate.inhibitCharging(reply: callback) }
        }.0)
        let activeWrites = smc.writes
        delegate.heartbeat { #expect($0) }
        delegate.heartbeat { #expect($0) }
        #expect(smc.writes == activeWrites)
        #expect(smc.readKeyOptional("CHTE")?.bytes == [1, 0, 0, 0])
        #expect(smc.readKeyOptional("CHIE")?.bytes == [discharge ? 8 : 0])
        #expect(state.state == .inhibited && delegate.requiresRecovery)
    }

    @Test("A newly verified thermal inhibition supersedes a failed recovery retry")
    func heartbeatDoesNotUndoNewInhibition() {
        let state = MemoryState(.inhibited)
        let smc = MockSMC(tahoe: true, state: state, openFailures: 2, inheritedDischarge: true)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(!delegate.resetChargingDirect())
        #expect(reply(delegate.inhibitCharging).0)
        #expect(smc.readKeyOptional("CHIE")?.bytes == [0])
        let inhibitedWrites = smc.writes
        delegate.heartbeat { #expect($0) }
        #expect(smc.writes == inhibitedWrites)
        #expect(smc.readKeyOptional("CHTE")?.bytes == [1, 0, 0, 0])
        #expect(state.state == .inhibited && delegate.requiresRecovery)
    }

    @Test("New charging policies are rejected until inherited discharge restoration succeeds", arguments: [0, 1, 2])
    func failedRecoveryCannotBeAdoptedAsNewPolicy(operation: Int) {
        let state = MemoryState(.inhibited)
        let smc = MockSMC(tahoe: true, failingKeys: ["CHIE"], state: state, inheritedDischarge: true)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(!delegate.resetChargingDirect())
        let result = reply { callback in
            switch operation {
            case 0: delegate.inhibitCharging(reply: callback)
            case 1: delegate.forceDischarge(enable: true, reply: callback)
            default: delegate.enableCharging(reply: callback)
            }
        }
        #expect(!result.0 && result.1 != nil)
        #expect(smc.readKeyOptional("CHIE")?.bytes == [8])
        #expect(!smc.writes.contains(.init(key: "CHTE", bytes: [1, 0, 0, 0])))
        #expect(!smc.writes.contains(.init(key: "CHIE", bytes: [8])))
        #expect(state.state == .inhibited && delegate.requiresRecovery)
        let attempts = smc.writes.count
        delegate.heartbeat { #expect($0) }
        #expect(smc.writes.count > attempts, "Failed recovery must remain scheduled for retry")
    }

    @Test("Cosmetic inherited recovery errors cannot block or undo thermal inhibition", arguments: [false, true])
    func cosmeticInheritedRecoveryStillAllowsInhibition(metadataFailure: Bool) {
        let state = MemoryState(.inhibited)
        let smc = MockSMC(tahoe: true, failingKeys: metadataFailure ? [] : ["ACLC"], state: state,
                          metadataFailures: metadataFailure ? ["ACLC": 20] : [:], inheritedDischarge: true)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(!delegate.resetChargingDirect())
        #expect(reply(delegate.inhibitCharging).0)
        #expect(smc.readKeyOptional("CHIE")?.bytes == [0])
        #expect(smc.readKeyOptional("CHTE")?.bytes == [1, 0, 0, 0])
        let inhibitedWrites = smc.writes
        delegate.heartbeat { #expect($0) }
        #expect(smc.writes == inhibitedWrites)
        #expect(state.state == .inhibited && delegate.requiresRecovery)
    }

    @Test("Transient discharge metadata failures never certify inherited discharge as reset", arguments: [false, true])
    func retryDischargeDetection(tahoe: Bool) {
        let state = MemoryState(.inhibited)
        let key = tahoe ? "CHIE" : "CH0I"
        let smc = MockSMC(tahoe: tahoe, state: state, metadataFailures: [key: 2])
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        // First probe was unknown. The first reset's probe is still unknown.
        #expect(!delegate.resetChargingDirect())
        #expect(smc.writes.contains(.init(key: key, bytes: [0])), "Unknown must not skip a possible inherited discharge gate")
        #expect(state.state == .inhibited)
        #expect(delegate.requiresRecovery)
        // Once metadata is readable, reset must actually stop discharge.
        #expect(delegate.resetChargingDirect())
        #expect(smc.writes.contains(.init(key: key, bytes: [0])))
        #expect(state.state == .normal)
    }

    @Test("A cosmetic LED error cannot re-enable a confirmed thermal inhibition")
    func cosmeticFailurePreservesChargingGates() {
        let state = MemoryState()
        let smc = MockSMC(failingNonzeroKeys: ["ACLC"], state: state)
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(reply(delegate.inhibitCharging).0)
        let chargingWrites = smc.writes.filter { $0.key != "ACLC" }
        #expect(!reply { delegate.setMagSafeLED(color: 3, reply: $0) }.0)
        #expect(smc.writes.filter { $0.key != "ACLC" } == chargingWrites)
        #expect(state.state == .inhibited)
        #expect(delegate.requiresRecovery)
    }

    @Test("An LED metadata error cannot block charging inhibition")
    func cosmeticMetadataErrorDoesNotBlockInhibition() {
        let state = MemoryState()
        let smc = MockSMC(state: state, metadataFailures: ["ACLC": 2])
        let delegate = HelperDelegate(watchdog: MockWatchdog(), smc: smc, stateStore: state)
        #expect(reply(delegate.inhibitCharging).0)
        #expect(smc.writes.contains(.init(key: "CH0B", bytes: [2])))
        #expect(state.state == .inhibited)
    }

    @Test("F08: the SDK idle sleep permission constant is the actual IOKit value")
    func SDKPowerConstants() {
        #expect(HelperPowerMessage.canSystemSleep.rawValue == 0xe0000270)
        #expect(HelperPowerMessage.systemWillSleep.rawValue == 0xe0000280)
        #expect(HelperPowerMessage.canSystemSleep.rawValue != HelperPowerMessage.systemWillSleep.rawValue)
    }
}

@Suite("Durable state files in temporary directories")
struct HelperStateFileTests {
    @Test func atomicRoundtripAndCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileHelperStateStore(directory: root.path)
        #expect(try store.read() == nil)
        try store.write(.inhibited)
        #expect(try store.read() == .inhibited)
        try store.write(.normal)
        #expect(try store.read() == .normal)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let file = root.appendingPathComponent("helper-state")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data("broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.read() }
    }

    @Test func refusesSymlinkDirectoryAndFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try FileHelperStateStore(directory: link.path).write(.inhibited) }
        let file = target.appendingPathComponent("helper-state")
        let unrelated = root.appendingPathComponent("unrelated")
        try Data("normal".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: unrelated)
        #expect(throws: (any Error).self) { try FileHelperStateStore(directory: target.path).read() }
        try FileHelperStateStore(directory: target.path).write(.inhibited)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "normal")
    }
}

@Suite("Caller requirements")
struct CallerAuthorizationTests {
    @Test func trustedTeamAndIdentifierAreRequired() throws {
        let requirement = try CallerAuthorization.requirement(teamIdentifier: "ABCDEFGHIJ", bundleIdentifier: HelperConstants.appBundleID)
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
        #expect(requirement.contains("identifier \"com.opendente.app\""))
        #expect(throws: (any Error).self) {
            try CallerAuthorization.requirement(teamIdentifier: "bad\" or true", bundleIdentifier: HelperConstants.appBundleID)
        }
        #expect(throws: (any Error).self) { try CallerAuthorization.currentHelperRequirement() }
    }

    @Test func forgedAdHocIdentifierIsDenied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("forged-app")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", "--identifier", HelperConstants.appBundleID, executable.path]
        signing.standardOutput = FileHandle.nullDevice
        signing.standardError = FileHandle.nullDevice
        try signing.run(); signing.waitUntilExit()
        #expect(signing.terminationStatus == 0)
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess)
        var weak: SecRequirement?
        #expect(SecRequirementCreateWithString("identifier \"com.opendente.app\"" as CFString, [], &weak) == errSecSuccess)
        let validCode = try #require(code)
        let weakRequirement = try #require(weak)
        #expect(SecStaticCodeCheckValidity(validCode, [], weakRequirement) == errSecSuccess)
        var strong: SecRequirement?
        let requirement = try CallerAuthorization.requirement(teamIdentifier: "ABCDEFGHIJ", bundleIdentifier: HelperConstants.appBundleID)
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &strong) == errSecSuccess)
        let strongRequirement = try #require(strong)
        #expect(SecStaticCodeCheckValidity(validCode, [], strongRequirement) != errSecSuccess)
    }
}
