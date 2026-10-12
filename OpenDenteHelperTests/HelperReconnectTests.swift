import Foundation
import Testing

private final class ReconnectFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let modes: [MockConnection.Heartbeat]
    private var storage: [MockConnection] = []
    init(_ modes: [MockConnection.Heartbeat]) { self.modes = modes }
    var connections: [MockConnection] { lock.withLock { storage } }
    func make() -> any HelperClientConnection {
        lock.withLock {
            let mode = storage.count < modes.count ? modes[storage.count] : .failure
            let connection = MockConnection(heartbeat: mode)
            storage.append(connection)
            return connection
        }
    }
}

/// Implements only in-process callbacks. No NSXPC connection or hardware is created.
private final class MockConnection: NSObject, HelperClientConnection, HelperProtocol, @unchecked Sendable {
    enum Heartbeat: Sendable { case success, failure, pending }
    private let lock = NSLock()
    private let heartbeatMode: Heartbeat
    private var invalidation: (@Sendable () -> Void)?
    private var interruption: (@Sendable () -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?
    private var heartbeatReplies: [(Bool) -> Void] = []
    private var errorBeforeEnableReply = false
    var invalidationHandler: (@Sendable () -> Void)? {
        get { lock.withLock { invalidation } }
        set { lock.withLock { invalidation = newValue } }
    }
    var interruptionHandler: (@Sendable () -> Void)? {
        get { lock.withLock { interruption } }
        set { lock.withLock { interruption = newValue } }
    }
    init(heartbeat: Heartbeat) { heartbeatMode = heartbeat }
    func resume() {}
    func invalidate() { invalidationHandler?() }
    func fireInvalidation() { invalidationHandler?() }
    func failEnableBeforeReply() { lock.withLock { errorBeforeEnableReply = true } }
    func completeHeartbeats(_ success: Bool) {
        let replies = lock.withLock { let current = heartbeatReplies; heartbeatReplies = []; return current }
        replies.forEach { $0(success) }
    }
    func proxy(errorHandler: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        lock.withLock { self.errorHandler = errorHandler }
        return self
    }
    func heartbeat(reply: @escaping (Bool) -> Void) {
        switch heartbeatMode {
        case .success: reply(true)
        case .failure: reply(false)
        case .pending: lock.withLock { heartbeatReplies.append(reply) }
        }
    }
    func enableCharging(reply: @escaping (Bool, String?) -> Void) {
        let callback = lock.withLock { errorBeforeEnableReply ? errorHandler : nil }
        callback?(NSError(domain: "Mock", code: 1))
        reply(true, nil)
    }
    func inhibitCharging(reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func forceDischarge(enable: Bool, reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func resetToDefaults(reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func suspendWatchdog(reply: @escaping (Bool) -> Void) { reply(true) }
    func getVersion(reply: @escaping (String) -> Void) { reply("1.4.0") }
    func getChargingAPI(reply: @escaping (String) -> Void) { reply("legacy") }
    func setMagSafeLED(color: UInt8, reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8, reply: @escaping (Bool) -> Void) { reply(true) }
}

private final class ResultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition() && clock.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    return condition()
}

@Suite("Helper reconnection without XPC", .serialized)
@MainActor
struct HelperReconnectTests {
    @Test("F16: default backoff exhausts after exactly five retries")
    func backoffPolicy() {
        var policy = HelperReconnectPolicy()
        let actual = (0..<6).map { _ in policy.nextDelay() }
        #expect(actual == [1, 2, 5, 10, 30, nil])
        #expect(policy.attempts == 5)
        policy.handshakeSucceeded()
        #expect(policy.nextDelay() == 1)
    }

    @Test("F16: repeated rejected handshakes cannot reset the retry counter")
    func rejectedHandshakesHaveBoundedRetries() async throws {
        let factory = ReconnectFactory([.failure])
        let client = HelperClient(connectionFactory: { factory.make() }, reconnectDelays: [0, 0, 0, 0, 0], handshakeTimeout: 1)
        defer { client.disconnect() }
        let restarts = ResultCounter()
        client.onHelperRestarted = { restarts.append(true) }
        client.connect()
        #expect(try await waitUntil { factory.connections.count == 6 })
        // Let queued invalidation tasks finish before checking the exhausted budget.
        for _ in 0..<10 { await Task.yield() }
        #expect(factory.connections.count == 6)
        #expect(restarts.values.isEmpty)
    }

    @Test("F16: a successful handshake restores the retry budget and emits resync once")
    func successfulHandshakeResetsBudget() async throws {
        let factory = ReconnectFactory([.failure, .failure, .success, .failure, .failure])
        let client = HelperClient(connectionFactory: { factory.make() }, reconnectDelays: [0, 0], handshakeTimeout: 1)
        defer { client.disconnect() }
        let restarts = ResultCounter()
        client.onHelperRestarted = { restarts.append(true) }
        client.connect()
        #expect(try await waitUntil { restarts.values.count == 1 })
        #expect(factory.connections.count == 3)
        factory.connections[2].fireInvalidation()
        #expect(try await waitUntil { factory.connections.count == 5 })
        #expect(restarts.values.count == 1)
    }

    @Test("F16: stale connection callbacks cannot invalidate a replacement")
    func staleInvalidationAndHeartbeatAreIgnored() async throws {
        let factory = ReconnectFactory([.pending, .success])
        let client = HelperClient(connectionFactory: { factory.make() }, reconnectDelays: [0], handshakeTimeout: 1)
        defer { client.disconnect() }
        client.connect()
        let old = factory.connections[0]
        client.connect()
        old.fireInvalidation()
        old.completeHeartbeats(false)
        for _ in 0..<10 { await Task.yield() }
        #expect(factory.connections.count == 2)
        let result = ResultCounter()
        client.enableCharging { success, _ in result.append(success) }
        #expect(try await waitUntil { !result.values.isEmpty })
        #expect(result.values == [true])
    }

    @Test("F16: intentional disconnect cancels a pending reconnect")
    func disconnectCancelsRetry() async throws {
        let factory = ReconnectFactory([.success])
        let client = HelperClient(connectionFactory: { factory.make() }, reconnectDelays: [0], handshakeTimeout: 1)
        client.connect()
        factory.connections[0].fireInvalidation()
        client.disconnect()
        for _ in 0..<10 { await Task.yield() }
        #expect(factory.connections.count == 1)
    }

    @Test("F16: a silent handshake times out and consumes the retry budget")
    func silentHandshakeTimesOut() async throws {
        let factory = ReconnectFactory([.pending, .pending])
        let client = HelperClient(connectionFactory: { factory.make() }, reconnectDelays: [0], handshakeTimeout: 0.01)
        defer { client.disconnect() }
        client.connect()
        #expect(try await waitUntil { factory.connections.count == 2 })
        for _ in 0..<10 { await Task.yield() }
        #expect(factory.connections.count == 2)
    }

    @Test("Proxy failure completes once even if a reply also arrives")
    func proxyErrorsAreReportedOnce() async throws {
        let factory = ReconnectFactory([.success])
        let client = HelperClient(connectionFactory: { factory.make() }, reconnectDelays: [], handshakeTimeout: 1)
        defer { client.disconnect() }
        client.connect()
        factory.connections[0].failEnableBeforeReply()
        let result = ResultCounter()
        client.enableCharging { success, _ in result.append(success) }
        #expect(try await waitUntil { !result.values.isEmpty })
        for _ in 0..<10 { await Task.yield() }
        #expect(result.values == [false])
    }

    @Test("Missing connection completes failures instead of leaving callers waiting")
    func disconnectedCommandCompletes() async throws {
        let factory = ReconnectFactory([.success])
        let client = HelperClient(connectionFactory: { factory.make() })
        let result = ResultCounter()
        client.inhibitCharging { success, _ in result.append(success) }
        #expect(try await waitUntil { !result.values.isEmpty })
        #expect(result.values == [false])
        #expect(factory.connections.isEmpty)
        // This path should return immediately rather than spending the termination timeout.
        let clock = ContinuousClock()
        let start = clock.now
        client.resetToDefaultsSync(timeout: 1)
        #expect(clock.now - start < .milliseconds(100))
    }
}
