import XCTest
@testable import SyncFieldInsta360

final class Insta360ScannerTests: XCTestCase {
    func test_shouldEmitDevice_acceptsGoName() {
        XCTAssertTrue(Insta360Scanner.shouldEmitDevice(name: "GO 3S 6GUCEB"))
    }

    func test_shouldEmitDevice_rejectsNonGo() {
        XCTAssertFalse(Insta360Scanner.shouldEmitDevice(name: "OGLO 100"))
    }

    func test_shouldEmitDevice_rejectsGoAsSubstring() {
        XCTAssertFalse(Insta360Scanner.shouldEmitDevice(name: "Govee Sensor"))
        XCTAssertFalse(Insta360Scanner.shouldEmitDevice(name: "GoPro 12"))
    }

    func test_shouldEmitDevice_rejectsNil() {
        XCTAssertFalse(Insta360Scanner.shouldEmitDevice(name: nil))
    }

    func test_shouldEmitDevice_caseInsensitive() {
        XCTAssertTrue(Insta360Scanner.shouldEmitDevice(name: "go 3s lowercase"))
    }

    func test_shouldAcceptDevice_rejectsExcludedUUID() {
        XCTAssertFalse(Insta360BLEController.shouldAcceptDevice(
            name: "GO 3S A",
            uuid: "AAAA-0005",
            excluding: ["AAAA-0005"]))
    }

    func test_actionCamHost_acceptsGo3Version() {
        XCTAssertTrue(Insta360BLEController.isGo3SActionCamHost(
            cameraType: nil,
            go3Version: "v1.0.63"))
    }

    func test_actionCamHost_acceptsGo3CameraTypeFallback() {
        XCTAssertTrue(Insta360BLEController.isGo3SActionCamHost(
            cameraType: "Insta360 GO 3S",
            go3Version: nil))
    }

    func test_actionCamHost_rejectsPodOnlyMetadata() {
        XCTAssertFalse(Insta360BLEController.isGo3SActionCamHost(
            cameraType: nil,
            go3Version: nil))
    }

    func test_recordingEndpoint_acceptsGoNameWhenMetadataUnavailable() {
        XCTAssertTrue(Insta360BLEController.isAcceptableGo3SRecordingEndpoint(
            name: "GO 3S 2BNMWH",
            cameraType: nil,
            go3Version: nil,
            boxVersion: nil))
    }

    func test_recordingEndpoint_rejectsBoxOnlyMetadata() {
        XCTAssertFalse(Insta360BLEController.isAcceptableGo3SRecordingEndpoint(
            name: "GO 3S 2BNMWH",
            cameraType: nil,
            go3Version: nil,
            boxVersion: "v1.0.1"))
    }

    func test_actionCamHost_rejectsOtherInsta360Models() {
        XCTAssertFalse(Insta360BLEController.isGo3SActionCamHost(
            cameraType: "Insta360 X4",
            go3Version: nil))
    }

    func test_dockStatus_resolvesUsbConnectionAsDocked() {
        XCTAssertEqual(Insta360BLEController.resolveDockStatus(
            chargeBoxStateRaw: 1,
            chargeboxUsbConnectedRaw: 2,
            chargeboxBtConnectedRaw: 1
        ), .docked)
    }

    func test_dockStatus_ignoresStateAndBtWhenUsbIsNotConnected() {
        XCTAssertEqual(Insta360BLEController.resolveDockStatus(
            chargeBoxStateRaw: 1,
            chargeboxUsbConnectedRaw: 1,
            chargeboxBtConnectedRaw: 2
        ), .separated)
        XCTAssertEqual(Insta360BLEController.resolveDockStatus(
            chargeBoxStateRaw: 1,
            chargeboxUsbConnectedRaw: nil,
            chargeboxBtConnectedRaw: 2
        ), .unknown)
    }

    func test_dockStatus_resolvesExplicitNoConnectionAsSeparated() {
        XCTAssertEqual(Insta360BLEController.resolveDockStatus(
            chargeBoxStateRaw: 0,
            chargeboxUsbConnectedRaw: 1,
            chargeboxBtConnectedRaw: 1
        ), .separated)
    }

    func test_dockStatus_keepsAmbiguousValuesUnknown() {
        XCTAssertEqual(Insta360BLEController.resolveDockStatus(
            chargeBoxStateRaw: nil,
            chargeboxUsbConnectedRaw: nil,
            chargeboxBtConnectedRaw: nil
        ), .unknown)
    }

    func test_withTimeout_successReturnsValueBeforeDeadline() async throws {
        let value = try await Insta360BLEController.withTimeout(seconds: 1.0) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    func test_withTimeout_throwsTimeoutWhenOperationExceedsDeadline() async {
        do {
            _ = try await Insta360BLEController.withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return 0
            }
            XCTFail("expected timeout error")
        } catch let Insta360Error.commandFailed(message) {
            XCTAssertTrue(message.contains("timed out"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
