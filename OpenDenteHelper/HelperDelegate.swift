import Foundation
import os.log

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "Delegate")

/// The lock serializes XPC commands, disconnect recovery and power callbacks.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol, @unchecked Sendable {
    private let smc: any HelperSMC
    private let watchdog: any HelperWatchdog
    private let stateStore: any HelperStateStore
    private let lock = NSLock()
    private let callerRequirement: String?
    private var chargingAPI: SMCChargingAPI = .unknown
    // Unknown optional capabilities must be attempted during restoration. Only a
    // successful metadata query proving absence may suppress a default write.
    private var hasMagSafeLED = true
    private var hasLegacyCompanion = true
    private var hasDischargeControl = true
    private var recoveryRequired = false
    // A durable override marker also represents valid inhibition/discharge.
    // Only inherited state or a failed restoration needs retries while the
    // owning app continues to send heartbeats.
    private var pendingRecoveryRetry = false
    private var lastResetHadCriticalFailure = false
    private var activeClients: Set<UUID> = []
    private var stopChargingWhenSleeping = false
    private var sleepLEDColor: UInt8 = 0xFF

    private enum ControlError: LocalizedError {
        case unsupported, missingDischarge, invalidLED, verification(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "No charging API detected"
            case .missingDischarge: return "No discharge control key detected"
            case .invalidLED: return "Unsupported MagSafe LED color"
            case .verification(let key): return "SMC readback did not confirm \(key)"
            }
        }
    }

    init(watchdog: any HelperWatchdog, smc: any HelperSMC = SMCService.shared,
         stateStore: any HelperStateStore = HelperState.store) {
        self.watchdog = watchdog
        self.smc = smc
        self.stateStore = stateStore
        callerRequirement = try? CallerAuthorization.currentHelperRequirement()
        super.init()
        do { recoveryRequired = try stateStore.read() == .inhibited }
        catch { recoveryRequired = true }
        pendingRecoveryRetry = recoveryRequired
        let failures = refreshCapabilitiesLocked()
        for failure in failures { log.error("SMC detection failed: \(failure.message, privacy: .public)") }
    }

    var requiresRecovery: Bool { lock.withLock { recoveryRequired } }

    private struct CapabilityFailure {
        let key: String
        let message: String
    }

    /// Optional metadata means genuinely absent. A thrown I/O/read error means
    /// unknown, so retain any prior capability and never certify defaults from it.
    /// Reopening and probing again also recovers from a transient startup failure.
    private func refreshCapabilitiesLocked() -> [CapabilityFailure] {
        do { try smc.open() }
        catch { return [CapabilityFailure(key: "connection", message: error.localizedDescription)] }
        var failures: [CapabilityFailure] = []
        func exists(_ key: String) -> Bool? {
            do { return try smc.keyInfoChecked(key) != nil }
            catch {
                failures.append(CapabilityFailure(key: key, message: "\(key): \(error.localizedDescription)"))
                return nil
            }
        }
        if let tahoe = exists("CHTE") {
            if tahoe { chargingAPI = .tahoe }
            else if let legacy = exists("CH0B") { chargingAPI = legacy ? .legacy : .unknown }
        }
        if chargingAPI == .legacy, let companion = exists("CH0C") { hasLegacyCompanion = companion }
        if chargingAPI != .unknown, let discharge = exists(dischargeKey) { hasDischargeControl = discharge }
        if let led = exists("ACLC") { hasMagSafeLED = led }
        return failures
    }

    /// LED availability and the discharge gate are independent of the charging gate.
    /// A cosmetic metadata error must not prevent thermal inhibition.
    private func chargingCapabilityFailures(_ failures: [CapabilityFailure]) -> [CapabilityFailure] {
        failures.filter { $0.key != "ACLC" && $0.key != "CHIE" && $0.key != "CH0I" }
    }

    private func capabilityError(_ failures: [CapabilityFailure]) -> (Bool, String?) {
        (false, failures.map(\.message).joined(separator: "; "))
    }

    /// Foundation rejects a mismatched sender before invoking the listener delegate.
    /// The team comes from the helper's verified Apple certificate, never a build setting.
    func configureAuthorization(on listener: NSXPCListener) -> Bool {
        guard let callerRequirement else {
            log.error("Refusing XPC service: helper must have a valid Apple-issued signature")
            return false
        }
        listener.setConnectionCodeSigningRequirement(callerRequirement)
        return true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let callerRequirement else { return false }
        connection.setCodeSigningRequirement(callerRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        let clientID = UUID()
        connection.invalidationHandler = { [weak self] in self?.clientDisconnected(clientID) }
        connection.interruptionHandler = { log.info("XPC client interrupted") }
        clientConnected(clientID)
        connection.resume()
        watchdog.receivedHeartbeat()
        return true
    }

    // Internal lifecycle entry points also let tests exercise recovery without an XPC daemon.
    func clientConnected(_ id: UUID) { lock.withLock { _ = activeClients.insert(id) } }

    func clientDisconnected(_ id: UUID) {
        lock.withLock {
            guard activeClients.remove(id) != nil, activeClients.isEmpty else { return }
            clearSleepPolicyLocked()
            watchdog.resume()
            if recoveryRequired { _ = resetLocked() }
        }
    }

    private func clearSleepPolicyLocked() {
        stopChargingWhenSleeping = false
        sleepLEDColor = 0xFF
    }

    /// Persist before *any* potentially unsafe write, including a cosmetic LED write.
    private func prepareRecoveryLocked() throws {
        recoveryRequired = true
        try stateStore.write(.inhibited)
    }

    private func writeChecked(_ key: String, _ bytes: [UInt8]) throws {
        try smc.writeKey(key, bytes: bytes)
        guard let value = smc.readKeyOptional(key), value.bytes.count >= bytes.count,
              Array(value.bytes.prefix(bytes.count)) == bytes else { throw ControlError.verification(key) }
    }

    private func chargingWrites(inhibited: Bool) throws -> [(String, [UInt8])] {
        switch chargingAPI {
        case .legacy:
            let byte: UInt8 = inhibited ? 2 : 0
            return [("CH0B", [byte])] + (hasLegacyCompanion ? [("CH0C", [byte])] : [])
        case .tahoe: return [("CHTE", [inhibited ? 1 : 0, 0, 0, 0])]
        case .unknown: throw ControlError.unsupported
        }
    }

    private var dischargeKey: String { chargingAPI == .tahoe ? "CHIE" : "CH0I" }

    private func failureLocked(_ error: Error, rollback: Bool) -> (Bool, String?) {
        var message = error.localizedDescription
        if rollback {
            let restoration = resetLocked()
            if let detail = restoration.1 { message += "; recovery: " + detail }
        }
        log.error("Control operation failed: \(message, privacy: .public)")
        return (false, message)
    }

    /// A newly requested charging policy cannot adopt an inherited, uncertain
    /// discharge gate. Complete its outstanding restoration first; only then
    /// can a verified new override be treated as legitimate active control.
    private func recoverBeforeNewPolicyLocked() -> (Bool, String?)? {
        guard pendingRecoveryRetry else { return nil }
        let restoration = resetLocked()
        // A failed cosmetic restoration may keep its durable marker, but must
        // not block a new thermal inhibition after charging/discharge recovery
        // was verified. Critical failures still prohibit a new policy.
        return restoration.0 || !lastResetHadCriticalFailure ? nil : restoration
    }

    private func inhibitLocked() -> (Bool, String?) {
        if let failure = recoverBeforeNewPolicyLocked() { return failure }
        let failures = chargingCapabilityFailures(refreshCapabilitiesLocked())
        guard failures.isEmpty else { return capabilityError(failures) }
        do {
            let writes = try chargingWrites(inhibited: true)
            // A persistence failure must not be followed by a hardware mutation.
            try prepareRecoveryLocked()
            do {
                for (key, bytes) in writes { try writeChecked(key, bytes) }
                // This is now an explicit, verified charging policy. A later
                // heartbeat must not undo it as if it were a failed reset.
                pendingRecoveryRetry = false
                return (true, nil)
            } catch { return failureLocked(error, rollback: true) }
        } catch { return failureLocked(error, rollback: false) }
    }

    func enableCharging(reply: @escaping (Bool, String?) -> Void) {
        let result: (Bool, String?) = lock.withLock {
            if let failure = recoverBeforeNewPolicyLocked() { return failure }
            var failures = chargingCapabilityFailures(refreshCapabilitiesLocked()).map(\.message)
            do {
                for (key, bytes) in try chargingWrites(inhibited: false) {
                    do { try writeChecked(key, bytes) }
                    catch { failures.append(error.localizedDescription) }
                }
                guard failures.isEmpty else { return failureLocked(ControlError.verification(failures.joined(separator: "; ")), rollback: true) }
                // Keep the recovery marker: discharge or LED overrides may still be active.
                // Only a complete reset may declare all defaults restored.
                pendingRecoveryRetry = false
                return (true, nil)
            } catch { return failureLocked(error, rollback: false) }
        }
        reply(result.0, result.1)
    }

    func inhibitCharging(reply: @escaping (Bool, String?) -> Void) {
        let result = lock.withLock { inhibitLocked() }
        reply(result.0, result.1)
    }

    func forceDischarge(enable: Bool, reply: @escaping (Bool, String?) -> Void) {
        let result: (Bool, String?) = lock.withLock {
            if let failure = recoverBeforeNewPolicyLocked() { return failure }
            let failures = refreshCapabilitiesLocked().filter { $0.key != "ACLC" }
            guard failures.isEmpty else { return capabilityError(failures) }
            guard chargingAPI != .unknown else { return (false, ControlError.unsupported.localizedDescription) }
            guard hasDischargeControl else { return (false, ControlError.missingDischarge.localizedDescription) }
            do {
                if enable { try prepareRecoveryLocked() }
            } catch { return failureLocked(error, rollback: false) }
            do {
                try writeChecked(dischargeKey, [enable ? (chargingAPI == .tahoe ? 8 : 1) : 0])
                if enable {
                    for (key, bytes) in try chargingWrites(inhibited: true) { try writeChecked(key, bytes) }
                }
                pendingRecoveryRetry = false
                return (true, nil)
            } catch { return failureLocked(error, rollback: true) }
        }
        reply(result.0, result.1)
    }

    func resetToDefaults(reply: @escaping (Bool, String?) -> Void) {
        let result = lock.withLock { resetLocked() }
        reply(result.0, result.1)
    }

    /// Attempt every independent restoration even when another key is unavailable or fails.
    /// Never erase the durable marker or return success while any step remains unconfirmed.
    private func resetLocked() -> (Bool, String?) {
        clearSleepPolicyLocked()
        watchdog.resume()
        let detectionFailures = refreshCapabilitiesLocked()
        var failures = detectionFailures.map(\.message)
        var criticalFailure = detectionFailures.contains { $0.key != "ACLC" }
        if hasDischargeControl {
            do { try writeChecked(dischargeKey, [0]) }
            catch { criticalFailure = true; failures.append(error.localizedDescription) }
        }
        do {
            for (key, bytes) in try chargingWrites(inhibited: false) {
                do { try writeChecked(key, bytes) }
                catch { criticalFailure = true; failures.append(error.localizedDescription) }
            }
        } catch { criticalFailure = true; failures.append(error.localizedDescription) }
        if hasMagSafeLED {
            do { try writeChecked("ACLC", [HelperConstants.ledAuto]) }
            catch { failures.append(error.localizedDescription) }
        }
        if failures.isEmpty {
            do { try stateStore.write(.normal) }
            catch { criticalFailure = true; failures.append(error.localizedDescription) }
        }
        lastResetHadCriticalFailure = criticalFailure
        recoveryRequired = !failures.isEmpty
        pendingRecoveryRetry = !failures.isEmpty
        if failures.isEmpty { return (true, nil) }
        let message = failures.joined(separator: "; ")
        log.error("Defaults remain unconfirmed: \(message, privacy: .public)")
        return (false, message)
    }

    @discardableResult
    func resetChargingDirect() -> Bool { lock.withLock { resetLocked().0 } }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        lock.withLock {
            if pendingRecoveryRetry { _ = resetLocked() }
        }
        watchdog.receivedHeartbeat()
        reply(true)
    }

    func suspendWatchdog(reply: @escaping (Bool) -> Void) {
        // Only an actual IOKit WillSleep notification may suspend crash recovery.
        // Retain the protocol method for older apps whose pre-sleep request can be canceled.
        reply(true)
    }

    func getVersion(reply: @escaping (String) -> Void) { reply(HelperConstants.helperVersion) }
    func getChargingAPI(reply: @escaping (String) -> Void) {
        let api = lock.withLock { chargingAPI }
        switch api {
        case .legacy: reply("legacy")
        case .tahoe: reply("tahoe")
        case .unknown: reply("unknown")
        }
    }

    private func validLED(_ color: UInt8) -> Bool {
        [HelperConstants.ledAuto, HelperConstants.ledOff, HelperConstants.ledGreen, HelperConstants.ledOrange].contains(color)
    }

    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8, reply: @escaping (Bool) -> Void) {
        let success = lock.withLock {
            guard !activeClients.isEmpty, sleepLEDColor == 0xFF || validLED(sleepLEDColor) else { return false }
            self.stopChargingWhenSleeping = stopChargingWhenSleeping
            self.sleepLEDColor = sleepLEDColor
            return true
        }
        reply(success)
    }

    func setMagSafeLED(color: UInt8, reply: @escaping (Bool, String?) -> Void) {
        let result: (Bool, String?) = lock.withLock {
            do {
                try smc.open()
                hasMagSafeLED = try smc.keyInfoChecked("ACLC") != nil
            } catch { return failureLocked(error, rollback: false) }
            guard hasMagSafeLED else { return (false, "No MagSafe LED (ACLC key not found)") }
            guard validLED(color) else { return (false, ControlError.invalidLED.localizedDescription) }
            do {
                if color != HelperConstants.ledAuto { try prepareRecoveryLocked() }
            } catch { return failureLocked(error, rollback: false) }
            do {
                try writeChecked("ACLC", [color])
                return (true, nil)
            } catch {
                // A cosmetic error must not undo an independently confirmed charging
                // inhibition. Retain the marker for later full recovery instead.
                return failureLocked(error, rollback: false)
            }
        }
        reply(result.0, result.1)
    }

    func inhibitChargingOnSleep() {
        lock.withLock {
            guard !activeClients.isEmpty, stopChargingWhenSleeping else { return }
            let result = inhibitLocked()
            guard result.0 else { return }
            // The marker already reached disk, so an LED failure cannot hide inhibition.
            if hasMagSafeLED, sleepLEDColor != 0xFF {
                do { try writeChecked("ACLC", [sleepLEDColor]) }
                catch { log.error("Sleep LED failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
}
