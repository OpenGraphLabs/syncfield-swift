import XCTest
@testable import SyncFieldInsta360

final class Insta360PendingResolverTests: XCTestCase {
    func test_matchSegments_returnsSingleCandidateInsideWindow() {
        let start = ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0)
        let window = Insta360PendingResolver.Window(
            startWallMs: start,
            endWallMs: start + 60_000,
            expectedDurationSec: 60,
            expectedSegments: 1)

        XCTAssertEqual(
            Insta360PendingResolver.matchSegments(uris: [
                "file:///DCIM/Camera01/VID_20260513_215000.mp4",
                "file:///DCIM/Camera01/VID_20260513_220000.mp4",
            ], window: window),
            ["file:///DCIM/Camera01/VID_20260513_220000.mp4"])
    }

    func test_matchSegments_expectedOnePicksClosestToStart() {
        let start = ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0)
        let window = Insta360PendingResolver.Window(
            startWallMs: start,
            endWallMs: start + 60_000,
            expectedDurationSec: 60,
            expectedSegments: 1)

        XCTAssertEqual(
            Insta360PendingResolver.matchSegments(uris: [
                "file:///DCIM/Camera01/VID_20260513_220045.mp4",
                "file:///DCIM/Camera01/VID_20260513_220003.mp4",
            ], window: window),
            ["file:///DCIM/Camera01/VID_20260513_220003.mp4"])
    }

    func test_matchSegments_returnsEmptyWhenCandidatesAreOutsideWindow() {
        let start = ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0)
        let window = Insta360PendingResolver.Window(
            startWallMs: start,
            endWallMs: start + 60_000,
            expectedDurationSec: 60,
            expectedSegments: 1)

        XCTAssertTrue(Insta360PendingResolver.matchSegments(uris: [
            "file:///DCIM/Camera01/VID_20260513_215000.mp4",
            "file:///DCIM/Camera01/VID_20260513_220200.mp4",
        ], window: window).isEmpty)
    }

    func test_matchSegments_expectedTwoReturnsAllSegmentsInTimestampOrder() {
        let start = ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0)
        let window = Insta360PendingResolver.Window(
            startWallMs: start,
            endWallMs: start + (20 * 60_000),
            expectedDurationSec: 1_200,
            expectedSegments: 2)

        XCTAssertEqual(
            Insta360PendingResolver.matchSegments(uris: [
                "file:///DCIM/Camera01/VID_20260513_221800.mp4",
                "file:///DCIM/Camera01/VID_20260513_220000.mp4",
            ], window: window),
            [
                "file:///DCIM/Camera01/VID_20260513_220000.mp4",
                "file:///DCIM/Camera01/VID_20260513_221800.mp4",
            ])
    }

    func test_matchSegments_ignoresBadNamesAndLowResolutionVideos() {
        let start = ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0)
        let window = Insta360PendingResolver.Window(
            startWallMs: start,
            endWallMs: start + 60_000,
            expectedDurationSec: 60,
            expectedSegments: 1)

        XCTAssertEqual(
            Insta360PendingResolver.matchSegments(uris: [
                "file:///DCIM/Camera01/VID_no_timestamp.mp4",
                "file:///DCIM/Camera01/LRV_20260513_220000.mp4",
                "file:///DCIM/Camera01/IMG_20260513_220000.jpg",
                "file:///DCIM/Camera01/VID_20260513_220000.insv",
            ], window: window),
            ["file:///DCIM/Camera01/VID_20260513_220000.insv"])
    }

    func test_matchSegments_allowsSmallCameraClockDrift() {
        let start = ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0)
        let window = Insta360PendingResolver.Window(
            startWallMs: start,
            endWallMs: start + 60_000,
            expectedDurationSec: 60,
            expectedSegments: 1)

        XCTAssertEqual(
            Insta360PendingResolver.matchSegments(uris: [
                "file:///DCIM/Camera01/VID_20260513_215955.mp4",
            ], window: window),
            ["file:///DCIM/Camera01/VID_20260513_215955.mp4"])
    }

    func test_parseFilenameTimestamp_acceptsUnderscoreAndDashFormats() {
        XCTAssertEqual(
            Insta360PendingResolver.parseFilenameTimestampMs(
                "VID_20260513_220000_001.mp4"),
            ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0))
        XCTAssertEqual(
            Insta360PendingResolver.parseFilenameTimestampMs(
                "VID_2026-05-13-220000.mp4"),
            ms(year: 2026, month: 5, day: 13, hour: 22, minute: 0, second: 0))
    }

    private func ms(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> UInt64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second))!
        return UInt64(date.timeIntervalSince1970 * 1000)
    }
}
