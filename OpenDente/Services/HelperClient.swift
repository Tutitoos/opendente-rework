import Foundation
import os.log

extension Notification.Name {
    // No payload or credentials; observers perform a fresh version probe.
    static let openDenteHelperConnectionLost = Notification.Name("OpenDente.HelperConnectionLost")
    static let openDenteHelperConnectionRestored = Notification.Name("OpenDente.HelperConnectionRestored")
}

private let log = Logger(subsystem: "com.opendente.app", category: "HelperClient")

/// A transport seam permits reconnect tests without contacting launchd or the real helper.
protocol HelperClientConnection: AnyObject, Sendable {
    var invalidationHandler: (@Sendable () -> Void)? { get set }
    var interruptionHandler: (@Sendable () -> Void)? { get set }
    func resume()
    func invalidate()
    func proxy(errorHandler: @escaping @Sendable (Error) -> Void) -> HelperProtocol?
}

private final class XPCClientConnection: HelperClientConnection, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let handlerLock = NSLock()
    private var invalidation: (@Sendable () -> Void)?
    private var interruption: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)? {
        get { handlerLock.withLock { invalidation } }
        set {
            handlerLock.withLock { invalidation = newValue }
            connection.invalidationHandler = newValue
        }
    }
    var interruptionHandler: (@Sendable () -> Void)? {
        get { handlerLock.withLock { interruption } }
        set {
            handlerLock.withLock { interruption = newValue }
            connection.interruptionHandler = newValue
        }
    }
    init() {
        connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    }
    func resume() { connection.resume() }
    func invalidate() { connection.invalidate() }
    func proxy(errorHandler: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler) as? HelperProtocol
    }
}

struct HelperReconnectPolicy: Sendable {
    let delays: [TimeInterval]
    private(set) var attempts = 0
    init(delays: [TimeInterval] = [1, 2, 5, 10, 30]) { self.delays = delays }
    mutating func nextDelay() -> TimeInterval? {
        guard attempts < delays.count else { return nil }
        defer { attempts += 1 }
        return delays[attempts]
    }
    mutating func handshakeSucceeded() { attempts = 0 }
}

/// A proxy error and a reply can race. Each operation reports exactly one result.
private final class HelperReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let completion: @Sendable (Value) -> Void
    init(_ completion: @escaping @Sendable (Value) -> Void) { self.completion = completion }
    func finish(_ value: Value) {
        let first = lock.withLock { if finished { return false }; finished = true; return true }
        if first { completion(value) }
    }
}

/// Connection state is protected by the lock; timers and callbacks to the manager run on main.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()
    private let lock = NSLock()
    private let connectionFactory: @Sendable () -> any HelperClientConnection
    private let handshakeTimeout: TimeInterval
    private var connection: (any HelperClientConnection)?
    private var generation = UUID()
    private var isIntentionalDisconnect = false
    private var reconnectPolicy: HelperReconnectPolicy
    private var pendingRestartNotification = false
    @MainActor private var heartbeatTimer: Timer?
    @MainActor private var reconnectWork: DispatchWorkItem?
    @MainActor private var handshakeWork: DispatchWorkItem?
    @MainActor var onHelperRestarted: (() -> Void)?

    init(connectionFactory: @escaping @Sendable () -> any HelperClientConnection = { XPCClientConnection() },
         reconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30], handshakeTimeout: TimeInterval = 5) {
        self.connectionFactory = connectionFactory
        self.reconnectPolicy = HelperReconnectPolicy(delays: reconnectDelays)
        self.handshakeTimeout = handshakeTimeout
    }

    @MainActor func connect() { beginConnection(notifyRestart: false) }

    @MainActor private func beginConnection(notifyRestart: Bool) {
        reconnectWork?.cancel()
        reconnectWork = nil
        handshakeWork?.cancel()
        stopHeartbeat()
        let id = UUID()
        let existing = lock.withLock {
            let old = connection
            connection = nil
            generation = id
            isIntentionalDisconnect = false
            pendingRestartNotification = notifyRestart
            return old
        }
        existing?.invalidate()
        let conn = connectionFactory()
        conn.invalidationHandler = { [weak self] in self?.connectionFailed(id: id) }
        conn.interruptionHandler = { [weak self] in self?.connectionFailed(id: id) }
        // Publish before resume: immediate errors must refer to the new generation.
        lock.withLock { connection = conn }
        conn.resume()
        let timeout = DispatchWorkItem { [weak self] in self?.connectionFailed(id: id) }
        handshakeWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + handshakeTimeout, execute: timeout)
        sendHeartbeat()
    }

    @MainActor func disconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        handshakeWork?.cancel()
        handshakeWork = nil
        stopHeartbeat()
        let old = lock.withLock {
            isIntentionalDisconnect = true
            generation = UUID()
            pendingRestartNotification = false
            let old = connection
            connection = nil
            return old
        }
        old?.invalidate()
    }

    private func connectionFailed(id: UUID) {
        let old: (any HelperClientConnection)? = lock.withLock {
            guard generation == id, !isIntentionalDisconnect, let old = connection else { return nil }
            connection = nil
            return old
        }
        guard let old else { return }
        old.invalidate()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { self.generation == id && !self.isIntentionalDisconnect && self.connection == nil }
            guard current else { return }
            NotificationCenter.default.post(name: .openDenteHelperConnectionLost, object: nil)
            self.stopHeartbeat()
            self.handshakeWork?.cancel()
            self.handshakeWork = nil
            self.scheduleReconnect(id: id)
        }
    }

    @MainActor private func scheduleReconnect(id: UUID) {
        let delay = lock.withLock { reconnectPolicy.nextDelay() }
        guard let delay else {
            log.notice("XPC reconnect budget exhausted; helper may need reinstallation")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { self.generation == id && !self.isIntentionalDisconnect && self.connection == nil }
            guard current else { return }
            self.beginConnection(notifyRestart: true)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handshakeSucceeded(id: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let notify: Bool? = self.lock.withLock {
                guard self.generation == id, self.connection != nil, !self.isIntentionalDisconnect else { return nil }
                self.reconnectPolicy.handshakeSucceeded()
                let notify = self.pendingRestartNotification
                self.pendingRestartNotification = false
                return notify
            }
            guard let notify else { return }
            self.handshakeWork?.cancel()
            self.handshakeWork = nil
            if self.heartbeatTimer == nil {
                self.startHeartbeat()
                NotificationCenter.default.post(name: .openDenteHelperConnectionRestored, object: nil)
            }
            if notify { self.onHelperRestarted?() }
        }
    }

    @MainActor private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: HelperConstants.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }
    @MainActor private func stopHeartbeat() { heartbeatTimer?.invalidate(); heartbeatTimer = nil }

    func sendHeartbeat() {
        let id = lock.withLock { generation }
        withProxy(failure: { [weak self] _ in self?.connectionFailed(id: id) }) { [weak self] helper in
            helper.heartbeat { [weak self] success in
                if success { self?.handshakeSucceeded(id: id) }
                else { self?.connectionFailed(id: id) }
            }
        }
    }

    private func command(completion: (@Sendable (Bool, String?) -> Void)?,
                         invoke: (HelperProtocol, @escaping (Bool, String?) -> Void) -> Void) {
        let reply = HelperReply<(Bool, String?)> { result in
            if let completion { DispatchQueue.main.async { completion(result.0, result.1) } }
        }
        withProxy(failure: { reply.finish((false, $0)) }) { helper in
            invoke(helper) { reply.finish(($0, $1)) }
        }
    }

    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        command(completion: completion) { $0.enableCharging(reply: $1) }
    }
    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        command(completion: completion) { $0.inhibitCharging(reply: $1) }
    }
    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        command(completion: completion) { $0.forceDischarge(enable: enable, reply: $1) }
    }
    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        command(completion: completion) { $0.resetToDefaults(reply: $1) }
    }
    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        command(completion: completion) { $0.setMagSafeLED(color: color, reply: $1) }
    }
    func suspendWatchdog() {
        withProxy { $0.suspendWatchdog { _ in } }
    }
    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8) {
        withProxy { $0.syncSleepSettings(stopChargingWhenSleeping: stopChargingWhenSleeping, sleepLEDColor: sleepLEDColor) { _ in } }
    }
    func getVersion(completion: @escaping @Sendable (String) -> Void) {
        let reply = HelperReply<String> { value in DispatchQueue.main.async { completion(value) } }
        withProxy(failure: { _ in reply.finish("") }) { $0.getVersion { reply.finish($0) } }
    }
    func getChargingAPI(completion: @escaping @Sendable (String) -> Void) {
        let reply = HelperReply<String> { value in DispatchQueue.main.async { completion(value) } }
        withProxy(failure: { _ in reply.finish("unknown") }) { $0.getChargingAPI { reply.finish($0) } }
    }

    /// Sent on the same connection after preceding commands, without blocking the main actor
    /// on a completion which itself needs the main actor.
    nonisolated func resetToDefaultsSync(timeout: TimeInterval = 2) {
        let semaphore = DispatchSemaphore(value: 0)
        let reply = HelperReply<Bool> { _ in semaphore.signal() }
        withProxy(failure: { _ in reply.finish(false) }) { $0.resetToDefaults { success, _ in reply.finish(success) } }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            log.warning("resetToDefaultsSync timed out; helper recovery remains responsible for restoring defaults")
        }
    }

    private func withProxy(failure: @escaping @Sendable (String) -> Void = { _ in }, block: (HelperProtocol) -> Void) {
        let (conn, id) = lock.withLock { (connection, generation) }
        guard let conn else { failure("Helper is not connected"); return }
        guard let proxy = conn.proxy(errorHandler: { [weak self] error in
            failure(error.localizedDescription)
            self?.connectionFailed(id: id)
        }) else {
            failure("Failed to obtain helper proxy")
            connectionFailed(id: id)
            return
        }
        block(proxy)
    }
}
