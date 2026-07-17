// Tests/SyncFieldTests/StereoCalibrationExtractionTests.swift
//
// Pure transform tests for the ultra-wide → wide extrinsics composition
// (`StereoExtrinsicsMath.stereoExtrinsics`). No AVFoundation involved — the
// helper takes raw `matrix_float4x3` extrinsic matrices (a simd type available
// on macOS), so these run on every platform.

import XCTest
import simd
@testable import SyncField

final class StereoCalibrationExtractionTests: XCTestCase {

    // MARK: - Fixture builders

    /// Build a `matrix_float4x3` extrinsic in the same column layout Apple uses
    /// for `AVCameraCalibrationData.extrinsicMatrix`: columns 0..2 are the 3x3
    /// rotation R, column 3 is the translation t.
    private func extrinsic(rotation R: simd_float3x3, translation t: SIMD3<Float>) -> matrix_float4x3 {
        matrix_float4x3(columns: (R.columns.0, R.columns.1, R.columns.2, t))
    }

    /// Identity rotation.
    private let identity = matrix_identity_float3x3

    /// Rotation of +90° about z, hardcoded (exact 0/1 entries → no FP slop).
    ///   Rz(90°) row-major = [0,-1,0, 1,0,0, 0,0,1]
    private var rotZ90: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(0, 1, 0),   // column 0
            SIMD3<Float>(-1, 0, 0),  // column 1
            SIMD3<Float>(0, 0, 1)    // column 2
        ))
    }

    /// Reconstruct a `simd_float3x3` from a row-major 9-element array (inverse
    /// of the helper's serialization) so tests can apply the composed rotation.
    private func matrix(fromRowMajor rm: [Float]) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(rm[0], rm[3], rm[6]),
            SIMD3<Float>(rm[1], rm[4], rm[7]),
            SIMD3<Float>(rm[2], rm[5], rm[8])
        ))
    }

    private func rotationX(_ radians: Float) -> simd_float3x3 {
        let c = cos(radians), s = sin(radians)
        return simd_float3x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, c, s),
            SIMD3<Float>(0, -s, c)
        ))
    }

    private func rotationZ(_ radians: Float) -> simd_float3x3 {
        let c = cos(radians), s = sin(radians)
        return simd_float3x3(columns: (
            SIMD3<Float>(c, s, 0),
            SIMD3<Float>(-s, c, 0),
            SIMD3<Float>(0, 0, 1)
        ))
    }

    // MARK: - Nil handling

    func test_both_nil_returns_nil() {
        XCTAssertNil(StereoExtrinsicsMath.stereoExtrinsics(fromUW: nil, wide: nil))
    }

    func test_uw_nil_returns_nil() {
        let wide = extrinsic(rotation: identity, translation: SIMD3(1, 2, 3))
        XCTAssertNil(StereoExtrinsicsMath.stereoExtrinsics(fromUW: nil, wide: wide))
    }

    func test_wide_nil_returns_nil() {
        let uw = extrinsic(rotation: identity, translation: SIMD3(1, 2, 3))
        XCTAssertNil(StereoExtrinsicsMath.stereoExtrinsics(fromUW: uw, wide: nil))
    }

    // MARK: - Identity reference cases

    /// UW is the reference (R_u = I, t_u = 0) so the composed UW→wide transform
    /// is exactly the wide camera's own extrinsic.
    func test_identity_uw_passes_wide_extrinsic_through() throws {
        let uw = extrinsic(rotation: identity, translation: SIMD3(0, 0, 0))
        let wide = extrinsic(rotation: identity, translation: SIMD3(19.2, 0, 0))

        let result = try XCTUnwrap(StereoExtrinsicsMath.stereoExtrinsics(fromUW: uw, wide: wide))

        XCTAssertEqual(result.rotationRowMajor, [1, 0, 0, 0, 1, 0, 0, 0, 1])
        assertClose(result.translationMillimeters, [19.2, 0, 0])
    }

    /// Pure-translation case with a non-zero UW translation: with both rotations
    /// identity, t = t_w − t_u.
    func test_pure_translation_subtracts_uw_offset() throws {
        let uw = extrinsic(rotation: identity, translation: SIMD3(5, 0, 0))
        let wide = extrinsic(rotation: identity, translation: SIMD3(24, 0, 0))

        let result = try XCTUnwrap(StereoExtrinsicsMath.stereoExtrinsics(fromUW: uw, wide: wide))

        XCTAssertEqual(result.rotationRowMajor, [1, 0, 0, 0, 1, 0, 0, 0, 1])
        assertClose(result.translationMillimeters, [19, 0, 0])
    }

    // MARK: - Row-major ordering

    /// With UW at the reference frame, the composed rotation equals the wide
    /// rotation. An asymmetric rotation (Rz(90°)) catches column/row transposition
    /// bugs in the serializer: row-major must be [0,-1,0, 1,0,0, 0,0,1].
    func test_row_major_ordering_asymmetric_rotation() throws {
        let uw = extrinsic(rotation: identity, translation: SIMD3(0, 0, 0))
        let wide = extrinsic(rotation: rotZ90, translation: SIMD3(1, 2, 3))

        let result = try XCTUnwrap(StereoExtrinsicsMath.stereoExtrinsics(fromUW: uw, wide: wide))

        XCTAssertEqual(result.rotationRowMajor, [0, -1, 0, 1, 0, 0, 0, 0, 1])
        assertClose(result.translationMillimeters, [1, 2, 3])
    }

    // MARK: - Full round-trip

    /// End-to-end derivation check: build UW and wide extrinsics from a shared
    /// reference-frame point, then confirm the composed UW→wide transform maps
    /// the UW-frame point to the wide-frame point. Exercises R_w·R_uᵀ, the
    /// t_w − R·t_u translation, AND the row-major serialization (the composed
    /// rotation is reconstructed from the returned row-major array).
    func test_round_trip_asymmetric_rotations() throws {
        let Ru = rotationZ(0.5236)   // 30°
        let tu = SIMD3<Float>(10, -2, 3)
        let Rw = rotationX(0.2618)   // 15°
        let tw = SIMD3<Float>(-4, 7, 11)

        let uw = extrinsic(rotation: Ru, translation: tu)
        let wide = extrinsic(rotation: Rw, translation: tw)

        let result = try XCTUnwrap(StereoExtrinsicsMath.stereoExtrinsics(fromUW: uw, wide: wide))

        let R = matrix(fromRowMajor: result.rotationRowMajor)
        let t = SIMD3<Float>(result.translationMillimeters[0],
                             result.translationMillimeters[1],
                             result.translationMillimeters[2])

        // For a set of reference points, p_uw = Ru·p_ref + tu and
        // p_wide = Rw·p_ref + tw; the composed transform must satisfy
        // p_wide == R·p_uw + t.
        for pRef in [SIMD3<Float>(7, 11, -5), SIMD3<Float>(-3, 2, 8), SIMD3<Float>(0, 0, 1)] {
            let pUW = Ru * pRef + tu
            let pWide = Rw * pRef + tw
            let mapped = R * pUW + t
            assertClose([mapped.x, mapped.y, mapped.z], [pWide.x, pWide.y, pWide.z], accuracy: 1e-3)
        }
    }

    /// The composed rotation must remain a proper rotation (orthonormal,
    /// det ≈ +1) for asymmetric inputs.
    func test_composed_rotation_is_orthonormal() throws {
        let uw = extrinsic(rotation: rotationZ(0.5236), translation: SIMD3(1, 2, 3))
        let wide = extrinsic(rotation: rotationX(0.7854), translation: SIMD3(4, 5, 6))

        let result = try XCTUnwrap(StereoExtrinsicsMath.stereoExtrinsics(fromUW: uw, wide: wide))
        let R = matrix(fromRowMajor: result.rotationRowMajor)

        let shouldBeIdentity = R * R.transpose
        assertClose(rowMajor(shouldBeIdentity), [1, 0, 0, 0, 1, 0, 0, 0, 1], accuracy: 1e-4)
        XCTAssertEqual(R.determinant, 1, accuracy: 1e-4)
    }

    // MARK: - Helpers

    private func rowMajor(_ m: simd_float3x3) -> [Float] {
        [m.columns.0.x, m.columns.1.x, m.columns.2.x,
         m.columns.0.y, m.columns.1.y, m.columns.2.y,
         m.columns.0.z, m.columns.1.z, m.columns.2.z]
    }

    private func assertClose(_ a: [Float], _ b: [Float], accuracy: Float = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "length mismatch", file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
        }
    }
}
