// Sources/SyncField/Calibration/StereoProbedCalibration.swift
import Foundation

/// Factory calibration data for BOTH constituent cameras of a dual-wide
/// virtual device (ultra-wide + wide), extracted from a one-time stereo
/// `AVCameraCalibrationData` photo probe.
///
/// NOTE: the stereo photo-calibration probe was removed in 0.11.1 (dual-wide
/// hardware cannot disable geometric distortion correction on the wide
/// constituent, so `isCameraCalibrationDataDeliverySupported` is structurally
/// false — see the CHANGELOG). This type survives only as the return container
/// of the still-present mono `PhotoCalibrationProbeExecutor.probe(deviceModel:)`
/// path (`.ultrawide`), which is the same dead photo probe and is slated for
/// later removal. It is no longer written to any on-device sidecar.
///
/// Extends the mono `ProbedCameraCalibration` probe (which retains only the
/// ultra-wide constituent) by also keeping the wide constituent, plus the
/// rigid transform between them.
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
