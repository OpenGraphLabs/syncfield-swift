// Tests/SyncFieldTests/ProbedCameraCalibrationTests.swift
import XCTest
@testable import SyncField

final class ProbedCameraCalibrationTests: XCTestCase {
    func test_json_round_trip_preserves_all_fields() throws {
        let original = ProbedCameraCalibration(
            fx: 1500.0, fy: 1500.1, cx: 2016.0, cy: 1512.0,
            referenceWidth: 4032, referenceHeight: 3024,
            lookupTableRadial: (0..<1024).map { Float($0) / 1024.0 },
            distortionCenterX: 2016.0, distortionCenterY: 1512.0,
            deviceModel: "iPhone17,1"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProbedCameraCalibration.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.lookupTableRadial.count, 1024)
        XCTAssertEqual(decoded.deviceModel, "iPhone17,1")
    }
}
