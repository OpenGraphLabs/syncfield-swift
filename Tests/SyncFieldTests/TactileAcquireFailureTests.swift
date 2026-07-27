import XCTest
@testable import SyncField

final class TactileAcquireFailureTests: XCTestCase {
    // MARK: reason(for:)

    func testScanTimeoutMapsToStableReason() {
        XCTAssertEqual(
            TactileAcquireFailure.reason(for: TactileBLEClient.Error.scanTimeout),
            "scan_timeout")
    }

    func testBluetoothUnavailableMapsToStableReason() {
        XCTAssertEqual(
            TactileAcquireFailure.reason(for: TactileBLEClient.Error.bluetoothUnavailable),
            "bluetooth_unavailable")
    }

    func testUnsupportedSchemaCarriesVersion() {
        XCTAssertEqual(
            TactileAcquireFailure.reason(for: TactileBLEClient.Error.unsupportedSchema(4)),
            "unsupported_schema_4")
    }

    func testConnectionErrorsMapToConnectFailed() {
        XCTAssertEqual(
            TactileAcquireFailure.reason(
                for: TactileBLEClient.Error.disconnected("connect timeout")),
            "connect_failed")
        XCTAssertEqual(
            TactileAcquireFailure.reason(
                for: TactileBLEClient.Error.missingCharacteristic),
            "connect_failed")
        struct SomeError: Error {}
        XCTAssertEqual(TactileAcquireFailure.reason(for: SomeError()), "connect_failed")
    }

    // MARK: deduper

    func testDeduperPublishesOnlyOnReasonChange() {
        var deduper = TactileAcquireFailureDeduper()
        XCTAssertTrue(deduper.shouldPublish("scan_timeout"))
        // An absent glove hits scan_timeout every ~13.5 s cycle — repeats
        // must not spam HealthBus/PostHog.
        XCTAssertFalse(deduper.shouldPublish("scan_timeout"))
        XCTAssertTrue(deduper.shouldPublish("bluetooth_unavailable"))
        XCTAssertFalse(deduper.shouldPublish("bluetooth_unavailable"))
        XCTAssertTrue(deduper.shouldPublish("scan_timeout"))
    }

    func testDeduperResetAllowsRepublishAfterRecovery() {
        var deduper = TactileAcquireFailureDeduper()
        XCTAssertTrue(deduper.shouldPublish("scan_timeout"))
        deduper.reset()
        XCTAssertTrue(deduper.shouldPublish("scan_timeout"))
    }
}
