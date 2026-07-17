// Sources/SyncField/Calibration/StereoExtrinsicsMath.swift
import Foundation
#if canImport(simd)
import simd
#endif

/// Rigid transform between two camera frames of a stereo pair — the row-major
/// 3x3 rotation plus a millimeter translation. Produced from Apple's
/// `AVCaptureDevice.extrinsicMatrix(from:to:)` (device-level factory
/// calibration) and consumed by the host when writing `cam_ego.calibration.json`
/// (spec §5.1). Pure value type — no AVFoundation — so it round-trips on any
/// platform.
public struct StereoExtrinsics: Codable, Equatable, Sendable {
    /// Row-major 3x3 rotation matrix, 9 values.
    public let rotationRowMajor: [Float]
    /// Translation in millimeters, 3 values (x, y, z).
    public let translationMillimeters: [Float]

    public init(rotationRowMajor: [Float], translationMillimeters: [Float]) {
        self.rotationRowMajor = rotationRowMajor
        self.translationMillimeters = translationMillimeters
    }
}

// MARK: - Pure extrinsics decode/composition (platform-independent)

#if canImport(simd)

/// Pure math over the simd `matrix_float4x3` extrinsic matrices Apple exposes.
/// Deliberately free of AVFoundation so it compiles and unit-tests on macOS —
/// `matrix_float4x3` is a simd type, not an AVFoundation one. This is the
/// surviving, reusable geometry layer: the device-level stereo extrinsics
/// written into `cam_ego.calibration.json` are decoded here, and the same
/// helpers back the (out-of-scope) mono photo-probe path.
enum StereoExtrinsicsMath {
    /// Composes the per-constituent extrinsics into the transform that maps a
    /// point expressed in the ultra-wide camera frame into the wide camera frame
    /// (spec §5.1 `ego_to_wide`). Returns nil unless both matrices are present.
    ///
    /// Apple, `AVCameraCalibrationData.extrinsicMatrix` — the matrix is a
    /// `matrix_float4x3` whose first three columns hold the camera's 3x3 rotation
    /// R and whose fourth column holds the translation t (millimeters), both
    /// expressed relative to the virtual device's reference (primary) constituent
    /// camera. So for a reference-frame point p_ref the point in camera c is
    ///     p_c = R_c · p_ref + t_c.
    ///
    /// We want UW → wide: given p_uw, produce p_wide. Since R_u is a rotation
    /// (R_u⁻¹ = R_uᵀ):
    ///     p_ref  = R_uᵀ · (p_uw − t_u)
    ///     p_wide = R_w · R_uᵀ · (p_uw − t_u) + t_w
    ///            = (R_w · R_uᵀ) · p_uw + (t_w − R_w · R_uᵀ · t_u)
    /// hence R = R_w · R_uᵀ and t = t_w − R · t_u.
    static func stereoExtrinsics(fromUW uwMatrix: matrix_float4x3?,
                                 wide wideMatrix: matrix_float4x3?) -> StereoExtrinsics? {
        guard let uwMatrix, let wideMatrix else { return nil }

        let rUW = rotation(of: uwMatrix)
        let tUW = uwMatrix.columns.3
        let rWide = rotation(of: wideMatrix)
        let tWide = wideMatrix.columns.3

        let rotationUWToWide = rWide * rUW.transpose        // R_w · R_uᵀ
        let translationUWToWide = tWide - rotationUWToWide * tUW  // t_w − R · t_u

        return StereoExtrinsics(
            rotationRowMajor: rowMajor(rotationUWToWide),
            translationMillimeters: [translationUWToWide.x,
                                     translationUWToWide.y,
                                     translationUWToWide.z]
        )
    }

    /// The direct extrinsics carried by a single `[R|t]` matrix that already
    /// expresses the desired from→to transform — no composition. Rotation is the
    /// first three columns (serialized row-major), translation is the fourth
    /// column (millimeters). Used for `AVCaptureDevice.extrinsicMatrix(from:to:)`,
    /// which per AVCaptureDevice.h maps X_to = [R|t]·X_from directly.
    static func directExtrinsics(fromMatrix m: matrix_float4x3) -> StereoExtrinsics {
        StereoExtrinsics(
            rotationRowMajor: rowMajor(rotation(of: m)),
            translationMillimeters: [m.columns.3.x, m.columns.3.y, m.columns.3.z]
        )
    }

    /// Decode Apple's `AVCaptureDevice.extrinsicMatrix(from:to:)` NSData payload —
    /// the native in-memory representation of a column-major `matrix_float4x3` —
    /// into direct extrinsics. Returns nil if the payload is smaller than a
    /// `matrix_float4x3` (defensive; Apple returns exactly that struct). Copies
    /// into an aligned stack value rather than `load(as:)` since `Data`'s backing
    /// bytes are not guaranteed to meet simd's 16-byte alignment.
    static func directExtrinsics(fromMatrixData data: Data) -> StereoExtrinsics? {
        let byteCount = MemoryLayout<matrix_float4x3>.size
        guard data.count >= byteCount else { return nil }
        var m = matrix_float4x3()
        withUnsafeMutableBytes(of: &m) { dst in
            _ = data.copyBytes(to: dst, count: byteCount)
        }
        return directExtrinsics(fromMatrix: m)
    }

    /// The rotation block (first three columns) of an extrinsic matrix as a
    /// column-major `simd_float3x3`.
    private static func rotation(of m: matrix_float4x3) -> simd_float3x3 {
        simd_float3x3(columns: (m.columns.0, m.columns.1, m.columns.2))
    }

    /// Flatten a column-major `simd_float3x3` into a row-major `[Float]` of 9.
    private static func rowMajor(_ m: simd_float3x3) -> [Float] {
        [m.columns.0.x, m.columns.1.x, m.columns.2.x,
         m.columns.0.y, m.columns.1.y, m.columns.2.y,
         m.columns.0.z, m.columns.1.z, m.columns.2.z]
    }
}

#endif // canImport(simd)
