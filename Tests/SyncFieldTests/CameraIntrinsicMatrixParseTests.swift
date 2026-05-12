import XCTest
@testable import SyncField

#if canImport(AVFoundation)
final class CameraIntrinsicMatrixParseTests: XCTestCase {
    func test_parse_reads_packed_column_major_data() {
        let floats: [Float] = [
            500, 0, 0,
            0, 510, 0,
            320, 240, 1,
        ]
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }

        let values = iPhoneCameraStream.parseIntrinsicMatrixData(data)

        XCTAssertEqual(values?.fx, 500)
        XCTAssertEqual(values?.fy, 510)
        XCTAssertEqual(values?.cx, 320)
        XCTAssertEqual(values?.cy, 240)
    }

    func test_parse_rejects_zero_focal_length() {
        let floats: [Float] = [
            0, 0, 0,
            0, 510, 0,
            320, 240, 1,
        ]
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }

        XCTAssertNil(iPhoneCameraStream.parseIntrinsicMatrixData(data))
    }

    func test_parse_rejects_short_payload() {
        let floats: [Float] = [500, 0, 0, 0, 510, 0, 320]  // only 7 floats
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }

        XCTAssertNil(iPhoneCameraStream.parseIntrinsicMatrixData(data))
    }
}
#endif
