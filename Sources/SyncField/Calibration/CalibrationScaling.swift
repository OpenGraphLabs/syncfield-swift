// Sources/SyncField/Calibration/CalibrationScaling.swift
import Foundation

/// Pinhole intrinsic values projected to a target image resolution.
public struct ScaledIntrinsics: Equatable, Sendable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
}

/// Pure-math helpers for rescaling pinhole intrinsics between resolutions.
///
/// `AVCameraCalibrationData.intrinsicMatrix` is calibrated against the
/// sensor's `intrinsicMatrixReferenceDimensions` (typically the full 4032×3024
/// photo capture). The recorded video runs at a smaller encoded resolution
/// (1920×1080 for our egocentric profile). To express the same lens model in
/// the video's pixel coordinates we rescale `(fx, fy, cx, cy)` proportionally
/// along each axis — valid for the pinhole projection inside the same active
/// crop region, which is what AVFoundation guarantees when GDC is off.
public enum CalibrationScaling {
    public static func scaleIntrinsics(
        fx: Double, fy: Double, cx: Double, cy: Double,
        referenceWidth: Int, referenceHeight: Int,
        encodedWidth: Int, encodedHeight: Int
    ) -> ScaledIntrinsics? {
        guard referenceWidth > 0, referenceHeight > 0 else { return nil }
        let sx = Double(encodedWidth) / Double(referenceWidth)
        let sy = Double(encodedHeight) / Double(referenceHeight)
        return ScaledIntrinsics(
            fx: fx * sx,
            fy: fy * sy,
            cx: cx * sx,
            cy: cy * sy
        )
    }
}
