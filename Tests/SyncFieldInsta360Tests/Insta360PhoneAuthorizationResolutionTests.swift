import XCTest
@testable import SyncFieldInsta360

final class Insta360PhoneAuthorizationResolutionTests: XCTestCase {
    func test_unauthorizedInitialStateWaitsForCameraUserDecision() {
        XCTAssertEqual(
            insta360PhoneAuthorizationInitialAction(rawState: 1),
            .waitForUserDecision)
    }

    func test_authorizedInitialStateCompletesImmediately() {
        XCTAssertEqual(
            insta360PhoneAuthorizationInitialAction(rawState: 0),
            .authorized)
    }

    func test_initialStateMapsBusyAndOtherDeviceAsImmediateFailures() {
        XCTAssertEqual(
            insta360PhoneAuthorizationInitialAction(rawState: 2),
            .fail(.systemBusy))
        XCTAssertEqual(
            insta360PhoneAuthorizationInitialAction(rawState: 3),
            .fail(.connectedByOtherPhone))
    }

    func test_userDecisionNotificationResultsMapToTerminalOutcomes() {
        XCTAssertEqual(insta360PhoneAuthorizationUserResult(rawResult: 1), .success)
        XCTAssertEqual(insta360PhoneAuthorizationUserResult(rawResult: 2), .reject)
        XCTAssertEqual(insta360PhoneAuthorizationUserResult(rawResult: 3), .timeout)
        XCTAssertEqual(insta360PhoneAuthorizationUserResult(rawResult: 4), .systemBusy)
    }
}
