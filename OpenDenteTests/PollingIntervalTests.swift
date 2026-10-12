import XCTest
@testable import OpenDente

@MainActor
final class PollingIntervalTests: XCTestCase {

    func testPollingInterval_isFixed2s() {
        XCTAssertEqual(BatteryService.pollingInterval, 2)
    }

    func testNativeHealthRefreshIsLowFrequencyAndExpires() {
        XCTAssertEqual(BatteryService.systemHealthRefreshInterval, 300)
        XCTAssertEqual(BatteryService.systemHealthCacheLifetime, 600)
        XCTAssertGreaterThan(BatteryService.systemHealthRefreshInterval, BatteryService.pollingInterval)
    }
}
