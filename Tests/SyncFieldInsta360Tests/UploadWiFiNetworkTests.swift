import XCTest
@testable import SyncFieldInsta360

final class UploadWiFiNetworkTests: XCTestCase {
    func test_profileRejectsBlankSSID() {
        XCTAssertNil(UploadWiFiProfile(ssid: "   ", passphrase: "password123"))
    }

    func test_profileTrimsSSIDButKeepsPassphraseVerbatim() throws {
        let profile = try XCTUnwrap(UploadWiFiProfile(
            ssid: "  Lab WiFi  ",
            passphrase: "  keep-spaces  "))

        XCTAssertEqual(profile.ssid, "Lab WiFi")
        XCTAssertEqual(profile.passphrase, "  keep-spaces  ")
    }

    func test_readyForKnownUploadWiFiRequiresMatchingSSIDAndWiFiPath() throws {
        let profile = try XCTUnwrap(UploadWiFiProfile(
            ssid: "Lab WiFi",
            passphrase: "password123"))

        XCTAssertTrue(UploadWiFiReconnector.isReadyForUpload(
            status: UploadNetworkStatus(
                interface: .wifi,
                ssid: "Lab WiFi",
                isExpensive: false,
                isConstrained: false),
            profile: profile))

        XCTAssertFalse(UploadWiFiReconnector.isReadyForUpload(
            status: UploadNetworkStatus(
                interface: .cellular,
                ssid: "Lab WiFi",
                isExpensive: true,
                isConstrained: false),
            profile: profile))

        XCTAssertFalse(UploadWiFiReconnector.isReadyForUpload(
            status: UploadNetworkStatus(
                interface: .wifi,
                ssid: "GO 3S ABC123.OSC",
                isExpensive: false,
                isConstrained: false),
            profile: profile))
    }

    func test_readyWithoutKnownProfileAcceptsNonExpensiveWiFiOnly() {
        XCTAssertTrue(UploadWiFiReconnector.isReadyForUpload(
            status: UploadNetworkStatus(
                interface: .wifi,
                ssid: "Office",
                isExpensive: false,
                isConstrained: false),
            profile: nil))

        XCTAssertFalse(UploadWiFiReconnector.isReadyForUpload(
            status: UploadNetworkStatus(
                interface: .cellular,
                ssid: nil,
                isExpensive: true,
                isConstrained: false),
            profile: nil))
    }

    func test_resolvedStatusTreatsKnownSSIDAsWiFiWhenPathSnapshotIsUnavailable() {
        let status = UploadWiFiReconnector.resolvedStatus(
            interface: .none,
            ssid: "Office",
            isExpensive: false,
            isConstrained: false)

        XCTAssertEqual(status.interface, .wifi)
        XCTAssertEqual(status.ssid, "Office")
    }

    func test_resolvedStatusKeepsCellularWhenIOSRoutesTrafficOverCellular() {
        let status = UploadWiFiReconnector.resolvedStatus(
            interface: .cellular,
            ssid: "Office",
            isExpensive: true,
            isConstrained: false)

        XCTAssertEqual(status.interface, .cellular)
        XCTAssertEqual(status.ssid, "Office")
    }

    func test_cameraHotspotPredicateOnlyTargetsInsta360APs() {
        XCTAssertTrue(Insta360WiFiDownloader.isLikelyCameraHotspotSSID("GO 3S ABC123.OSC"))
        XCTAssertTrue(Insta360WiFiDownloader.isLikelyCameraHotspotSSID("X4 123456.OSC"))
        XCTAssertFalse(Insta360WiFiDownloader.isLikelyCameraHotspotSSID("Office WiFi"))
        XCTAssertFalse(Insta360WiFiDownloader.isLikelyCameraHotspotSSID("osc-lab-router"))
    }

    func test_hotspotApplyFailureDescriptionIncludesKind() {
        let error = Insta360Error.hotspotApplyFailedWithKind(
            kind: .userDenied,
            detail: "user denied")

        XCTAssertTrue(error.localizedDescription.contains("userDenied"))
        XCTAssertTrue(error.localizedDescription.contains("user denied"))
    }
}
