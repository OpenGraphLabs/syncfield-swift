import XCTest
@testable import SyncField

#if canImport(AVFoundation)
final class CameraMidpointTimestampTests: XCTestCase {
    func test_midpoint_timestamp_shifts_by_half_exposure() {
        let stamp = iPhoneCameraStream.midpointCorrectedTimestampNs(
            ptsSeconds: 123.0,
            exposureSeconds: 0.016
        )

        XCTAssertEqual(stamp.rawPtsNs, 123_000_000_000)
        XCTAssertEqual(stamp.captureNs - stamp.rawPtsNs, 8_000_000)
    }
}
#endif
