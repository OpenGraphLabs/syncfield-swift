import XCTest
@testable import SyncFieldInsta360

final class Insta360PhoneAuthorizationPolicyTests: XCTestCase {
    func test_requiresExplicitAuthorizationWhenSerialIsKnownButCacheIsMissing() {
        XCTAssertTrue(
            Insta360CameraStream.shouldRequestExplicitPhoneAuthorization(
                serialLast6: "7W3DGW",
                isCachedAuthorized: false))
    }

    func test_skipsExplicitAuthorizationWhenPhoneIsCachedAuthorized() {
        XCTAssertFalse(
            Insta360CameraStream.shouldRequestExplicitPhoneAuthorization(
                serialLast6: "7W3DGW",
                isCachedAuthorized: true))
    }

    func test_skipsExplicitAuthorizationWhenSerialCannotBeResolved() {
        XCTAssertFalse(
            Insta360CameraStream.shouldRequestExplicitPhoneAuthorization(
                serialLast6: nil,
                isCachedAuthorized: false))
    }
}
