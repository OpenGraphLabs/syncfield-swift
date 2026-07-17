// Sources/SyncField/Streams/CameraDeviceConfig.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

#if os(iOS) && canImport(AVFoundation)
/// Camera device configuration helpers shared between `iPhoneCameraStream`
/// and the upcoming multi-camera stream (`MultiCamCameraStream`, Task A5).
/// Extracted from `iPhoneCameraStream` so both stream types rank formats,
/// clamp fps, and lock zoom identically instead of duplicating the logic.
enum CameraDeviceConfig {
    /// Pick the widest-FOV format on `device` that satisfies `settings`,
    /// ranked by widest field of view, then closest aspect ratio to the
    /// requested output, then highest pixel count. When `requireMultiCam`
    /// is `true`, only formats with `isMultiCamSupported == true` are
    /// considered — required when `device` is one input of an
    /// `AVCaptureMultiCamSession`.
    static func widestUsableFormat(
        on device: AVCaptureDevice,
        settings: VideoSettings,
        requireMultiCam: Bool = false
    ) -> AVCaptureDevice.Format? {
        let targetFps = Double(settings.fps)
        let requestedPixels = Int64(settings.width) * Int64(settings.height)
        let requestedAspect = Double(settings.width) / Double(settings.height)

        let eligibleFormats = requireMultiCam
            ? device.formats.filter { $0.isMultiCamSupported }
            : device.formats

        let fpsCompatible = eligibleFormats.filter { format in
            supports(format: format, fps: targetFps)
        }
        let resolutionCompatible = fpsCompatible.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int64(dimensions.width) * Int64(dimensions.height) >= requestedPixels
        }
        let pool = !resolutionCompatible.isEmpty
            ? resolutionCompatible
            : (!fpsCompatible.isEmpty ? fpsCompatible : eligibleFormats)

        return pool.max { lhs, rhs in
            let lhsFov = lhs.videoFieldOfView
            let rhsFov = rhs.videoFieldOfView
            if abs(lhsFov - rhsFov) > 0.1 {
                return lhsFov < rhsFov
            }

            let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsAspect = Double(lhsDimensions.width) / Double(lhsDimensions.height)
            let rhsAspect = Double(rhsDimensions.width) / Double(rhsDimensions.height)
            let lhsAspectDelta = abs(lhsAspect - requestedAspect)
            let rhsAspectDelta = abs(rhsAspect - requestedAspect)
            if abs(lhsAspectDelta - rhsAspectDelta) > 0.01 {
                return lhsAspectDelta > rhsAspectDelta
            }

            let lhsPixels = Int64(lhsDimensions.width) * Int64(lhsDimensions.height)
            let rhsPixels = Int64(rhsDimensions.width) * Int64(rhsDimensions.height)
            return lhsPixels > rhsPixels
        }
    }

    /// Strict availability predicate for `MultiCamCameraStream`'s support
    /// gate: does `device` expose at least one format that is
    /// multicam-capable AND at least `minWidth`×`minHeight` AND covers
    /// `fps`? Unlike `widestUsableFormat(requireMultiCam:)`, this does NOT
    /// fall back to a smaller/slower format when nothing matches — the gate
    /// must fail loud (Jerry's no-fallback rule) rather than silently
    /// recording a stereo pair the hardware can't actually sustain at spec.
    static func hasMultiCamFormat(
        on device: AVCaptureDevice,
        minWidth: Int,
        minHeight: Int,
        fps: Double
    ) -> Bool {
        device.formats.contains { format in
            guard format.isMultiCamSupported else { return false }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) >= minWidth,
                  Int(dimensions.height) >= minHeight else { return false }
            return supports(format: format, fps: fps)
        }
    }

    private static func supports(format: AVCaptureDevice.Format, fps: Double) -> Bool {
        guard fps > 0 else { return true }
        return format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= fps && range.maxFrameRate >= fps
        }
    }

    /// Clamp `format`'s frame rate to `targetFps` when the format supports
    /// it; otherwise fall back to the format's highest supported rate.
    static func appliedFrameRate(
        for format: AVCaptureDevice.Format,
        targetFps: Int
    ) -> Double? {
        let target = Double(targetFps)
        guard target > 0 else { return nil }
        if format.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= target && $0.maxFrameRate >= target
        }) {
            return target
        }
        return format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max()
    }

    /// Select the widest usable format, clamp its frame rate to
    /// `settings.fps`, and lock zoom to the device's minimum — equivalent
    /// to 0.5× on a modern back-camera array, keeping capture at the
    /// physical ultra-wide framing rather than a cropped virtual-camera
    /// default. Manages its own `lockForConfiguration`/
    /// `unlockForConfiguration` pair.
    ///
    /// GDC-off and stabilization-off are per-`AVCaptureConnection` state,
    /// not per-device, so those stay at each stream's own call sites
    /// rather than moving here.
    static func applyLensPolicy(
        _ device: AVCaptureDevice,
        settings: VideoSettings,
        requireMultiCam: Bool = false
    ) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if let format = widestUsableFormat(on: device, settings: settings, requireMultiCam: requireMultiCam) {
                device.activeFormat = format
            }

            if let fps = appliedFrameRate(for: device.activeFormat, targetFps: settings.fps) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps.rounded()))))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }

            device.videoZoomFactor = device.minAvailableVideoZoomFactor
        } catch {
            NSLog("[SyncField.Camera] failed to configure widest FOV: \(error)")
        }
    }
}
#endif
