// Sources/SyncField/Calibration/StereoProbedCalibration.swift
import Foundation

/// Rigid transform between two camera frames of a virtual device, captured
/// from `AVCameraCalibrationData.extrinsicMatrix` during a stereo calibration
/// probe (see `StereoProbedCalibration`).
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

/// Factory calibration data for BOTH constituent cameras of a dual-wide
/// virtual device (ultra-wide + wide), extracted from a one-time stereo
/// `AVCameraCalibrationData` photo probe and persisted to disk per device
/// model.
///
/// Extends the mono `ProbedCameraCalibration` probe (which retains only the
/// ultra-wide constituent) by also keeping the wide constituent, plus the
/// rigid transform between them so downstream pipelines can reproject
/// ultra-wide points into the wide camera frame (spec §5.1 `ego_to_wide`).
public struct StereoProbedCalibration: Codable, Equatable, Sendable {
    public let ultrawide: ProbedCameraCalibration
    public let wide: ProbedCameraCalibration
    /// Points in the ultrawide camera frame → wide camera frame (spec §5.1 ego_to_wide).
    public let extrinsicsUWToWide: StereoExtrinsics?
    /// Device-level AVCaptureDevice.extrinsicMatrix(from: uw, to: wide) snapshot for cross-check.
    public let deviceExtrinsicsUWToWide: StereoExtrinsics?
    public let probedAtISO8601: String

    public init(
        ultrawide: ProbedCameraCalibration,
        wide: ProbedCameraCalibration,
        extrinsicsUWToWide: StereoExtrinsics?,
        deviceExtrinsicsUWToWide: StereoExtrinsics?,
        probedAtISO8601: String
    ) {
        self.ultrawide = ultrawide
        self.wide = wide
        self.extrinsicsUWToWide = extrinsicsUWToWide
        self.deviceExtrinsicsUWToWide = deviceExtrinsicsUWToWide
        self.probedAtISO8601 = probedAtISO8601
    }

    /// Euclidean norm of `extrinsicsUWToWide.translationMillimeters`, falling
    /// back to `deviceExtrinsicsUWToWide` when the probe extrinsics are nil.
    /// `nil` when both are absent.
    public var baselineMillimeters: Float? {
        guard let translation = extrinsicsUWToWide?.translationMillimeters
            ?? deviceExtrinsicsUWToWide?.translationMillimeters
        else {
            return nil
        }
        let sumOfSquares = translation.reduce(Float(0)) { $0 + $1 * $1 }
        return sumOfSquares.squareRoot()
    }
}

/// Seam for the stereo (ultra-wide + wide) calibration probe. Mirrors
/// `PhotoCalibrationProbeExecutor` for the mono path but is kept as its own
/// protocol — `PhotoCalibrationProbeExecutor` has no `probeStereo` member
/// yet — so `CameraCalibrationProber` stays fully unit-testable via a stub,
/// without pulling in AVFoundation. `AVPhotoCalibrationProbeExecutor` (or a
/// wrapper) conforms to this once the stereo photo probe lands.
public protocol StereoCalibrationProbeExecutor: Sendable {
    func probeStereo(deviceModel: String) async throws -> StereoProbedCalibration
}
