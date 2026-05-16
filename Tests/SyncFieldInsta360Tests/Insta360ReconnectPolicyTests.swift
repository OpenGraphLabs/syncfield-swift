import XCTest
@testable import SyncFieldInsta360

final class Insta360ReconnectPolicyTests: XCTestCase {

    // MARK: - Backoff schedule

    func testDefaultBackoffSchedule() {
        let p = Insta360ReconnectPolicy()
        XCTAssertEqual(p.backoffSeconds(forAttempt: 1), 0.5)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 2), 1)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 3), 2)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 4), 4)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 5), 8)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 6), 15)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 7), 30)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 8), 60)
    }

    func testBackoffSaturatesAtSteadyState() {
        let p = Insta360ReconnectPolicy()
        XCTAssertEqual(p.backoffSeconds(forAttempt: 10), 60)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 100), 60)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 1_000_000), 60)
    }

    func testBackoffAtZeroAttemptDefaultsToFirstSlot() {
        let p = Insta360ReconnectPolicy()
        XCTAssertEqual(p.backoffSeconds(forAttempt: 0), 0.5)
        XCTAssertEqual(p.backoffSeconds(forAttempt: -3), 0.5)
    }

    func testCustomScheduleIsRespected() {
        let p = Insta360ReconnectPolicy(backoffScheduleSeconds: [1, 1, 1, 5, 30])
        XCTAssertEqual(p.backoffSeconds(forAttempt: 1), 1)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 4), 5)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 5), 30)
        XCTAssertEqual(p.backoffSeconds(forAttempt: 99), 30)
    }

    // MARK: - Persistent classifier

    func testClassifierFiresAfterScanWindowThreshold() {
        let config = Insta360CoordinatorConfig.shared
        config.persistentScanWindowCount = 3

        XCTAssertFalse(Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: 2,
            lastErrorDescription: nil,
            msSinceLastAdvertisement: nil,
            config: config))

        XCTAssertTrue(Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: 3,
            lastErrorDescription: nil,
            msSinceLastAdvertisement: nil,
            config: config))

        XCTAssertTrue(Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: 99,
            lastErrorDescription: nil,
            msSinceLastAdvertisement: nil,
            config: config))
    }

    func testClassifierMatchesPersistentErrorMarkers() {
        let cfg = Insta360CoordinatorConfig.shared
        for marker in [
            "Peripheral powered off",
            "Out of range",
            "User Disconnect requested",
            "CBError.peripheralDisconnected.userDisconnect",
        ] {
            XCTAssertTrue(
                Insta360ReconnectPolicy.shouldClassifyAsLost(
                    consecutiveScanWindowsWithoutAdvert: 0,
                    lastErrorDescription: marker,
                    msSinceLastAdvertisement: nil,
                    config: cfg),
                "Marker \"\(marker)\" should classify as lost")
        }
    }

    func testClassifierIgnoresTransientErrors() {
        let cfg = Insta360CoordinatorConfig.shared
        XCTAssertFalse(Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: 0,
            lastErrorDescription: "Command timed out",
            msSinceLastAdvertisement: nil,
            config: cfg))
    }

    func testClassifierFiresOnLongIdleAdvertisementGap() {
        let cfg = Insta360CoordinatorConfig.shared
        cfg.persistentLastSeenThresholdSeconds = 90

        XCTAssertFalse(Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: 0,
            lastErrorDescription: nil,
            msSinceLastAdvertisement: 80_000,
            config: cfg))

        XCTAssertTrue(Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: 0,
            lastErrorDescription: nil,
            msSinceLastAdvertisement: 91_000,
            config: cfg))
    }
}
