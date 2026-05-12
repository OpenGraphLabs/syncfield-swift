import XCTest
@testable import SyncFieldInsta360

final class Insta360VideoURIFallbackTests: XCTestCase {
    func test_bestCandidatePrefersNewestTimestampedVideo() {
        let uris = [
            "file:///DCIM/Camera01/VID_20260512_101000.insv",
            "file:///DCIM/Camera01/LRV_20260512_120000.mp4",
            "file:///DCIM/Camera01/VID_20260512_113000.insv",
        ]

        XCTAssertEqual(
            Insta360VideoURIFallback.bestCandidate(from: uris),
            "file:///DCIM/Camera01/VID_20260512_113000.insv")
    }

    func test_bestCandidatePrefersMp4OverInsvForSameTimestamp() {
        let uris = [
            "file:///DCIM/Camera01/VID_20260512_113000.insv",
            "file:///DCIM/Camera01/VID_20260512_113000.mp4",
        ]

        XCTAssertEqual(
            Insta360VideoURIFallback.bestCandidate(from: uris),
            "file:///DCIM/Camera01/VID_20260512_113000.mp4")
    }

    func test_bestCandidateReturnsNilWhenNoDownloadableVideoExists() {
        XCTAssertNil(Insta360VideoURIFallback.bestCandidate(from: [
            "file:///DCIM/Camera01/LRV_20260512_113000.mp4",
            "file:///DCIM/Camera01/IMG_20260512_113000.jpg",
        ]))
    }
}
