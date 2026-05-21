// Tests/SyncFieldTests/CameraCalibrationScalingTests.swift
//
// Pure-math unit tests for the intrinsic-rescaling helper used when probed
// `AVCameraCalibrationData` (calibrated at sensor reference dimensions, e.g.
// 4032×3024) needs to be projected to the encoded video resolution (e.g.
// 1920×1080) before being written into `camera_intrinsics.json`'s top-level
// `fx/fy/cx/cy` fields.

import XCTest
@testable import SyncField

final class CameraCalibrationScalingTests: XCTestCase {
    func test_scale_intrinsics_to_encoded_resolution() {
        // Reference: full-sensor 4032×3024 (AVCameraCalibrationData typical)
        // Encoded:   1920×1080 (egocentric 1080p video)
        // fx_probe = 1500 → fx_video = 1500 * (1920/4032) ≈ 714.2857
        // fy_probe = 1500 → fy_video = 1500 * (1080/3024) ≈ 535.7143
        let scaled = CalibrationScaling.scaleIntrinsics(
            fx: 1500.0, fy: 1500.0,
            cx: 2016.0, cy: 1512.0,
            referenceWidth: 4032, referenceHeight: 3024,
            encodedWidth: 1920, encodedHeight: 1080
        )
        let s = try! XCTUnwrap(scaled)
        XCTAssertEqual(s.fx, 1500.0 * 1920.0 / 4032.0, accuracy: 1e-6)
        XCTAssertEqual(s.fy, 1500.0 * 1080.0 / 3024.0, accuracy: 1e-6)
        XCTAssertEqual(s.cx, 2016.0 * 1920.0 / 4032.0, accuracy: 1e-6)
        XCTAssertEqual(s.cy, 1512.0 * 1080.0 / 3024.0, accuracy: 1e-6)
    }

    func test_scale_identity_when_reference_equals_encoded() {
        // Same reference and encoded dimensions → unchanged values.
        let scaled = CalibrationScaling.scaleIntrinsics(
            fx: 705.3, fy: 705.3, cx: 960.0, cy: 540.0,
            referenceWidth: 1920, referenceHeight: 1080,
            encodedWidth: 1920, encodedHeight: 1080
        )
        let s = try! XCTUnwrap(scaled)
        XCTAssertEqual(s.fx, 705.3, accuracy: 1e-9)
        XCTAssertEqual(s.fy, 705.3, accuracy: 1e-9)
        XCTAssertEqual(s.cx, 960.0, accuracy: 1e-9)
        XCTAssertEqual(s.cy, 540.0, accuracy: 1e-9)
    }

    func test_scale_returns_nil_when_reference_width_is_zero() {
        // Defensive: refuse div-by-zero rather than producing NaN/Inf values.
        let scaled = CalibrationScaling.scaleIntrinsics(
            fx: 1500.0, fy: 1500.0, cx: 2016.0, cy: 1512.0,
            referenceWidth: 0, referenceHeight: 3024,
            encodedWidth: 1920, encodedHeight: 1080
        )
        XCTAssertNil(scaled)
    }

    func test_scale_returns_nil_when_reference_height_is_zero() {
        let scaled = CalibrationScaling.scaleIntrinsics(
            fx: 1500.0, fy: 1500.0, cx: 2016.0, cy: 1512.0,
            referenceWidth: 4032, referenceHeight: 0,
            encodedWidth: 1920, encodedHeight: 1080
        )
        XCTAssertNil(scaled)
    }

    func test_scale_returns_nil_when_reference_dimension_is_negative() {
        let scaled = CalibrationScaling.scaleIntrinsics(
            fx: 1500.0, fy: 1500.0, cx: 2016.0, cy: 1512.0,
            referenceWidth: -4032, referenceHeight: 3024,
            encodedWidth: 1920, encodedHeight: 1080
        )
        XCTAssertNil(scaled)
    }
}
