import XCTest
@testable import SyncFieldInsta360

final class Insta360CaptureRetryPolicyTests: XCTestCase {
    func test_stopRetryPolicyUsesLongerTimeoutsForLaterAttempts() {
        XCTAssertEqual(Insta360CaptureRetryPolicy.maxStopAttempts, 4)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 1), 15)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 2), 20)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 3), 25)
        XCTAssertEqual(Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: 4), 30)
    }

    func test_recoverableStopErrorsIncludeSdkExecuteAndDisconnectFailures() {
        XCTAssertTrue(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("msg execute err")))
        XCTAssertTrue(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("BLE command manager unavailable")))
        XCTAssertTrue(Insta360CaptureRetryPolicy.isRecoverableCommandError(
            Insta360Error.commandFailed("operation timed out after 15.0s")))
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
