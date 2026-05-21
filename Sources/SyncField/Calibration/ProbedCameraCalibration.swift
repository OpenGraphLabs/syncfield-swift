// Sources/SyncField/Calibration/ProbedCameraCalibration.swift
import Foundation

/// Factory calibration data extracted from a one-time `AVCameraCalibrationData`
/// photo probe and persisted to disk per device model.
///
/// Captured against the sensor's reference dimensions (typically the full
/// photo resolution, e.g. 4032×3024). Hosts rescale `fx/fy/cx/cy` to the
/// recorded video resolution at write time via `CalibrationScaling`.
///
/// `lookupTableRadial` is Apple's 1024-point radial distortion lookup table
/// describing the lens's geometric distortion at the reference dimensions.
/// Together with `distortionCenter` it lets downstream pipelines undistort
/// fisheye-raw frames (or, equivalently, project 3D points correctly).
public struct ProbedCameraCalibration: Sendable, Codable, Equatable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public let referenceWidth: Int
    public let referenceHeight: Int
    public let lookupTableRadial: [Float]
    public let distortionCenterX: Double
    public let distortionCenterY: Double
    public let deviceModel: String

    public init(
        fx: Double, fy: Double, cx: Double, cy: Double,
        referenceWidth: Int, referenceHeight: Int,
        lookupTableRadial: [Float],
        distortionCenterX: Double, distortionCenterY: Double,
        deviceModel: String
    ) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
        self.lookupTableRadial = lookupTableRadial
        self.distortionCenterX = distortionCenterX
        self.distortionCenterY = distortionCenterY
        self.deviceModel = deviceModel
    }
}
