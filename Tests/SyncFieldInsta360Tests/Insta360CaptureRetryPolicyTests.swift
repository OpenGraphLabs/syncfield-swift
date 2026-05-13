import XCTest
@testable import SyncFieldInsta360

final class Insta360CaptureRetryPolicyTests: XCTestCase {
    func test_stopRetryPolicyUsesLongerTimeoutsForLaterAttempts() {
        XCTAssertEqual(Insta360CaptureRetryPolicy.maxStopAttempts, 4)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 1), 6)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 2), 10)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 3), 14)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 4), 18)
    }

    func test_recordingSafetyLimitCapsAtThirtyMinutes() {
        XCTAssertEqual(Insta360CaptureRetryPolicy.recordingSafetyLimitSeconds, 1_800)
    }

    func test_recoverableStopErrorsIncludeSdkExecuteAndDisconnectFailures() {
        XCTAssertTrue(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("msg execute err")))
        XCTAssertTrue(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("BLE command manager unavailable")))
        XCTAssertTrue(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("operation timed out after 15.0s")))
        XCTAssertFalse(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("stopCapture returned nil videoInfo.uri")))
    }

    func test_alreadyStoppedErrorsAreDetectedSeparately() {
        XCTAssertTrue(Insta360CaptureRetryPolicy.indicatesAlreadyStopped(
            Insta360Error.commandFailed("camera is not recording")))
        XCTAssertTrue(Insta360CaptureRetryPolicy.indicatesAlreadyStopped(
            Insta360Error.commandFailed("capture stopped")))
        XCTAssertFalse(Insta360CaptureRetryPolicy.indicatesAlreadyStopped(
            Insta360Error.commandFailed("BLE disconnected")))
    }
}
