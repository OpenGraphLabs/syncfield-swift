// Sources/SyncField/Streams/CameraTimestamps.swift
import Foundation

#if canImport(AVFoundation)
/// Timestamp helpers shared between `iPhoneCameraStream` and
/// `MultiCamCameraStream`. Kept in its own `canImport(AVFoundation)`-gated
/// file (not `os(iOS)`-only) so macOS `swift test` keeps building it and
/// `CameraMidpointTimestampTests` can pin the midpoint-correction behaviour
/// without a device.
enum CameraTimestamps {
    /// Shift an AVFoundation presentation timestamp from the exposure *start*
    /// (what `CMSampleBufferGetPresentationTimeStamp` reports) to the optical
    /// *midpoint* that VIO wants, by adding half the active exposure
    /// duration. Returns both the corrected capture timestamp and the raw
    /// PTS, in nanoseconds. Negative inputs and non-finite exposures are
    /// clamped so the result is always a valid `UInt64`.
    static func midpointCorrectedTimestampNs(
        ptsSeconds: Double,
        exposureSeconds: Double
    ) -> (captureNs: UInt64, rawPtsNs: UInt64) {
        let safeExposure = exposureSeconds.isFinite ? max(0.0, exposureSeconds) : 0.0
        let rawPtsNs = UInt64(max(0.0, ptsSeconds) * 1_000_000_000)
        let captureNs = UInt64(max(0.0, ptsSeconds + safeExposure / 2.0) * 1_000_000_000)
        return (captureNs, rawPtsNs)
    }
}
#endif
