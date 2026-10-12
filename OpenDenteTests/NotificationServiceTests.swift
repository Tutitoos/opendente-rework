import XCTest
import UserNotifications
@testable import OpenDente

@MainActor
final class NotificationServiceTests: XCTestCase {

    private let suiteName = "com.opendente.tests.notifications"
    private var service: NotificationService!
    private var settings: AppSettings!
    private var sender: RecordingNotificationSender!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        sender = RecordingNotificationSender()
        service = NotificationService(sender: sender)
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        service = nil
        settings = nil
        sender = nil
    }

    // MARK: - Gating

    func testSend_whenDisabled_doesNotTrackEvent() {
        settings.showNotifications = false
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertNil(service.lastEvent, "Should not track event when notifications disabled")
    }

    func testSend_whenEventDisabled_doesNotTrack() {
        settings.notifyHeatProtection = false
        service.send(.heatProtection, settings: settings)
        XCTAssertNil(service.lastEvent, "Should not track event when that event type is disabled")
    }

    func testSend_otherEventsStillWorkWhenOneDisabled() {
        settings.notifyHeatProtection = false
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached, "Other events should still fire")
    }

    // MARK: - Anti-Spam

    func testSend_sameEventTwice_blocksSecond() {
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)

        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)
        XCTAssertEqual(sender.requests.count, 1)
    }

    func testSend_differentEvent_allowed() {
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)

        service.send(.heatProtection, settings: settings)
        XCTAssertEqual(service.lastEvent, .heatProtection)
    }

    func testClearLastEvent_allowsRedelivery() {
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)

        service.clearLastEvent()
        XCTAssertNil(service.lastEvent)

        // Same event should now be allowed again
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)
        XCTAssertEqual(sender.requests.count, 2)
    }
}

@MainActor
final class RecordingNotificationSender: NotificationDelivering {
    var requests: [UNNotificationRequest] = []
    var error: Error?
    var defersDelivery = false
    var completions: [@MainActor (Error?) -> Void] = []
    func add(_ request: UNNotificationRequest, completion: @escaping @MainActor (Error?) -> Void) {
        requests.append(request)
        if defersDelivery { completions.append(completion) } else { completion(error) }
    }
}
