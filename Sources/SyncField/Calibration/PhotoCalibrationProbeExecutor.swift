// Sources/SyncField/Calibration/PhotoCalibrationProbeExecutor.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(simd)
import simd
#endif

/// Single-call interface that performs the actual one-time photo capture and
/// returns a `ProbedCameraCalibration`. Real implementation drives
/// `AVCapturePhotoOutput` on iOS; tests inject a stub so prober caching and
/// error semantics are testable without an AVCaptureSession.
public protocol PhotoCalibrationProbeExecutor: Sendable {
    func probe(deviceModel: String) async throws -> ProbedCameraCalibration
}

#if canImport(AVFoundation) && os(iOS)

/// Real iOS implementation that performs the calibration probe.
///
/// Apple gates `AVCameraCalibrationData` delivery on:
///   1. The photo output running through a **virtual device** with two or
///      more constituent devices selected for virtual-device constituent
///      photo delivery (single `.builtInUltraWideCamera` does not qualify).
///   2. `contentAwareDistortionCorrectionEnabled = false` on the output.
///   3. `geometricDistortionCorrectionEnabled = false` on every constituent
///      device.
///
/// We therefore probe via `.builtInDualWideCamera` (ultra-wide + wide,
/// available on every iPhone with an ultra-wide back camera since iPhone
/// 11). The probe captures one virtual-device photo, AVFoundation invokes
/// the delegate twice — once per constituent device — and we KEEP both the
/// ultra-wide and wide calibrations plus the rigid transform between them
/// (`StereoProbedCalibration`). The mono `probe(deviceModel:)` entry point
/// runs the same capture and returns the ultra-wide half.
public final class AVPhotoCalibrationProbeExecutor: NSObject, PhotoCalibrationProbeExecutor, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 3.0) {
        self.timeout = timeout
        super.init()
    }

    /// Mono entry point — shares the stereo capture path and returns the
    /// ultra-wide constituent. A single virtual-device capture delivers both
    /// constituents, so there is no separate, lighter code path (Jerry's rule:
    /// one clear path, no fallback).
    public func probe(deviceModel: String) async throws -> ProbedCameraCalibration {
        try await runStereoProbe(deviceModel: deviceModel).ultrawide
    }

    private func runStereoProbe(deviceModel: String) async throws -> StereoProbedCalibration {
        NSLog("[SyncField.Probe] begin deviceModel=\(deviceModel)")

        // Permission gate first — we run BEFORE the recording session starts,
        // so on first launch the user hasn't seen the camera prompt yet.
        // Explicitly request access so the probe and the subsequent record
        // share the same one-time grant. If the user is still deciding the
        // continuation suspends until they tap Allow/Deny.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        NSLog("[SyncField.Probe] authorizationStatus=\(status.rawValue)")
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            NSLog("[SyncField.Probe] requestAccess result granted=\(granted)")
            guard granted else { throw ProbeError.permissionDenied }
        case .denied, .restricted:
            throw ProbeError.permissionDenied
        @unknown default:
            throw ProbeError.permissionDenied
        }

        // Prefer DualWide over Triple — Apple sample paths uniformly use
        // DualWide for calibration delivery, and Triple has been reported
        // to return cameraCalibrationDataDeliverySupported=false even when
        // every other precondition is met. Triple stays as a last-resort
        // fallback for devices that may not expose DualWide.
        let virtualDeviceCandidates: [(String, AVCaptureDevice?)] = [
            ("dualWide", AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)),
            ("triple",   AVCaptureDevice.default(.builtInTripleCamera,   for: .video, position: .back)),
        ]
        for (label, dev) in virtualDeviceCandidates {
            NSLog("[SyncField.Probe] candidate \(label): \(dev?.deviceType.rawValue ?? "nil")")
        }
        guard let virtualDevice = virtualDeviceCandidates.compactMap({ $0.1 }).first else {
            NSLog("[SyncField.Probe] no virtual device available")
            throw ProbeError.unsupportedDevice
        }
        NSLog("[SyncField.Probe] selected virtual device=\(virtualDevice.deviceType.rawValue)")
        let dualWide = virtualDevice

        // Constituent physical devices on a dual-wide are
        // `[builtInUltraWideCamera, builtInWideAngleCamera]` (triple adds
        // tele). Lock each and disable GDC so calibration delivery becomes
        // supported.
        let constituents = dualWide.constituentDevices
        NSLog("[SyncField.Probe] constituents=[\(constituents.map { $0.deviceType.rawValue }.joined(separator: ", "))]")
        for device in constituents {
            do {
                try device.lockForConfiguration()
                if device.isGeometricDistortionCorrectionSupported {
                    device.isGeometricDistortionCorrectionEnabled = false
                    NSLog("[SyncField.Probe] GDC OFF on \(device.deviceType.rawValue): enabled=\(device.isGeometricDistortionCorrectionEnabled)")
                } else {
                    NSLog("[SyncField.Probe] GDC toggle not supported on \(device.deviceType.rawValue)")
                }
                device.unlockForConfiguration()
            } catch {
                throw ProbeError.underlying("lockForConfiguration failed for \(device.deviceType.rawValue): \(error)")
            }
        }

        // Device-level factory extrinsics between the two physical constituents,
        // independent of the photo capture. `AVCaptureDevice.extrinsicMatrix(from:to:)`
        // (iOS 13+) returns an NSData wrapping a column-major `matrix_float4x3`
        // `[R|t]` such that X_to = [R|t]·X_from with t in millimeters (see
        // AVCaptureDevice.h). Called (from: ultra-wide, to: wide) it is ALREADY the
        // UW→wide transform — no composition needed. Apple provides it only for
        // physical cameras that have a factory calibration; virtual cameras (and
        // any device lacking one) return nil, in which case we record nil.
        let ultrawideDevice = constituents.first { $0.deviceType == .builtInUltraWideCamera }
        let wideDevice = constituents.first { $0.deviceType == .builtInWideAngleCamera }
        var deviceExtrinsics: StereoExtrinsics?
        if let ultrawideDevice, let wideDevice,
           let matrixData = AVCaptureDevice.extrinsicMatrix(from: ultrawideDevice, to: wideDevice) {
            deviceExtrinsics = StereoExtrinsicsMath.directExtrinsics(fromMatrixData: matrixData)
            NSLog("[SyncField.Probe] device-level extrinsics: \(deviceExtrinsics != nil ? "decoded" : "unparseable") bytes=\(matrixData.count)")
        } else {
            deviceExtrinsics = nil
            NSLog("[SyncField.Probe] device-level extrinsics unavailable (nil)")
        }

        // Build a transient capture session distinct from the recording one.
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: dualWide)
        } catch {
            session.commitConfiguration()
            throw ProbeError.underlying("AVCaptureDeviceInput failed: \(error)")
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw ProbeError.unsupportedDevice
        }
        session.addInput(input)

        let photoOutput = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            NSLog("[SyncField.Probe] canAddOutput failed")
            throw ProbeError.unsupportedDevice
        }
        session.addOutput(photoOutput)

        // Raise the output's max prioritization to .quality so the settings
        // can request the same level. Going the other way (settings > max)
        // raises an uncatchable NSException at capturePhoto. Some iOS
        // versions only generate calibration data on the .quality path.
        photoOutput.maxPhotoQualityPrioritization = .quality
        NSLog("[SyncField.Probe] maxPhotoQualityPrioritization=\(photoOutput.maxPhotoQualityPrioritization.rawValue)")

        // Required pre-conditions for camera calibration data delivery.
        NSLog("[SyncField.Probe] CAD pre: supported=\(photoOutput.isContentAwareDistortionCorrectionSupported) enabled=\(photoOutput.isContentAwareDistortionCorrectionEnabled)")
        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = false
            NSLog("[SyncField.Probe] CAD post: enabled=\(photoOutput.isContentAwareDistortionCorrectionEnabled)")
        }

        if photoOutput.isVirtualDeviceConstituentPhotoDeliverySupported {
            photoOutput.isVirtualDeviceConstituentPhotoDeliveryEnabled = true
            NSLog("[SyncField.Probe] virtualDeviceConstituentPhotoDelivery enabled")
        } else {
            session.commitConfiguration()
            NSLog("[SyncField.Probe] virtualDeviceConstituentPhotoDelivery NOT supported on this device")
            throw ProbeError.unsupportedDevice
        }

        // **Undocumented Apple requirement**: depth-data delivery must ALSO
        // be enabled for calibration delivery to actually work, even though
        // we don't consume the depth data. Forum thread 131829 confirms:
        // "cameraCalibrationData returns nil when cameraCalibrationDataDeliveryEnabled
        //  is true unless depthDataDeliveryEnabled is also true."
        let depthSupported = photoOutput.isDepthDataDeliverySupported
        NSLog("[SyncField.Probe] depthDataDelivery.supported=\(depthSupported) enabled-pre=\(photoOutput.isDepthDataDeliveryEnabled)")
        if depthSupported {
            photoOutput.isDepthDataDeliveryEnabled = true
            NSLog("[SyncField.Probe] depthDataDelivery enabled-post=\(photoOutput.isDepthDataDeliveryEnabled)")
        }

        let calibSupported = photoOutput.isCameraCalibrationDataDeliverySupported
        NSLog("[SyncField.Probe] cameraCalibrationDataDelivery.supported=\(calibSupported)")

        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        // Match photoOutput.maxPhotoQualityPrioritization, which we set to
        // .quality above. Going higher raises an uncatchable NSException.
        settings.photoQualityPrioritization = .quality
        // Select all constituents so AVFoundation will deliver one photo
        // per device, each carrying its own calibration data. We keep the
        // ultra-wide AND wide photos; any others (tele) are discarded.
        settings.virtualDeviceConstituentPhotoDeliveryEnabledDevices = constituents
        // Settings-level enable would raise an Objective-C exception (which
        // Swift can't catch) if calibrationSupported is false. Gate strictly.
        if calibSupported {
            settings.isCameraCalibrationDataDeliveryEnabled = true
            // Pair with depth delivery on the settings — same undocumented
            // requirement as the output-level toggle above.
            settings.isDepthDataDeliveryEnabled = true
            NSLog("[SyncField.Probe] settings: calibrationDelivery=true, depthDelivery=true, quality=high")
        } else {
            NSLog("[SyncField.Probe] skipping settings calibration enable — output.supported=false")
        }

        let delegate = StereoProbeDelegate(deviceModel: deviceModel, deviceExtrinsics: deviceExtrinsics)
        NSLog("[SyncField.Probe] capturePhoto fired")
        photoOutput.capturePhoto(with: settings, delegate: delegate)

        let result = try await withThrowingTaskGroup(of: StereoProbedCalibration.self) { group in
            group.addTask {
                try await delegate.awaitResult()
            }
            group.addTask { [timeout] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProbeError.probeTimeout
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw ProbeError.probeTimeout
            }
            group.cancelAll()
            return first
        }

        // Sanity guard: a plausible UW↔wide baseline on iPhones is ~2 cm. If the
        // composed baseline falls outside a generous band we still return the
        // data (the app-side writer records it verbatim); we only flag it.
        if let baseline = result.baselineMillimeters, baseline < 5 || baseline > 200 {
            NSLog("[StereoProbe] baseline outside sanity band")
        }

        NSLog("[SyncField.Probe] SUCCESS uw.fx=\(result.ultrawide.fx) wide.fx=\(result.wide.fx) baselineMM=\(result.baselineMillimeters.map { String($0) } ?? "nil") extrinsics=\(result.extrinsicsUWToWide != nil ? "present" : "nil")")
        return result
    }
}

/// Photo-capture delegate for the stereo probe. AVFoundation delivers one
/// `didFinishProcessingPhoto:` callback per constituent device when virtual-
/// device constituent photo delivery is enabled. We retain BOTH the ultra-wide
/// and wide calibrations and resume once both have arrived; other constituents
/// (tele) are ignored. Any error, or a UW/wide photo missing usable calibration,
/// fails the whole probe.
private final class StereoProbeDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let deviceModel: String
    /// Device-level UW→wide extrinsics from `AVCaptureDevice.extrinsicMatrix(from:to:)`,
    /// computed before capture; nil when the SDK returns no factory data.
    private let deviceExtrinsics: StereoExtrinsics?
    private var continuation: CheckedContinuation<StereoProbedCalibration, Error>?
    private let lock = NSLock()

    // Per-constituent state, guarded by `lock`.
    private var uwProbed: ProbedCameraCalibration?
    private var wideProbed: ProbedCameraCalibration?
    private var uwExtrinsic: matrix_float4x3?
    private var wideExtrinsic: matrix_float4x3?

    init(deviceModel: String, deviceExtrinsics: StereoExtrinsics?) {
        self.deviceModel = deviceModel
        self.deviceExtrinsics = deviceExtrinsics
        super.init()
    }

    func awaitResult() async throws -> StereoProbedCalibration {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // Suppress shutter UI artefacts.
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            NSLog("[SyncField.Probe] delegate error: \(error)")
            resume(throwing: .underlying("didFinishProcessingPhoto: \(error)"))
            return
        }

        let sourceType = photo.sourceDeviceType
        let calibPresent = photo.cameraCalibrationData != nil
        NSLog("[SyncField.Probe] delegate photo arrived: source=\(sourceType?.rawValue ?? "nil") calibration=\(calibPresent ? "present" : "nil")")

        // Only the two dual-wide constituents matter; ignore any others (tele).
        guard sourceType == .builtInUltraWideCamera || sourceType == .builtInWideAngleCamera else {
            return
        }
        guard let calibration = photo.cameraCalibrationData else {
            NSLog("[SyncField.Probe] \(sourceType?.rawValue ?? "?") photo arrived but calibration data missing")
            resume(throwing: .calibrationDataMissing)
            return
        }
        guard let probed = Self.probedCalibration(from: calibration, deviceModel: deviceModel) else {
            resume(throwing: .calibrationDataMissing)
            return
        }

        lock.lock()
        if sourceType == .builtInUltraWideCamera {
            uwProbed = probed
            uwExtrinsic = calibration.extrinsicMatrix
        } else {
            wideProbed = probed
            wideExtrinsic = calibration.extrinsicMatrix
        }
        let uw = uwProbed
        let wide = wideProbed
        let uwEx = uwExtrinsic
        let wideEx = wideExtrinsic
        lock.unlock()

        guard let uw, let wide else {
            // Still waiting for the other constituent.
            return
        }

        let extrinsics = StereoExtrinsicsMath.stereoExtrinsics(fromUW: uwEx, wide: wideEx)
        let stereo = StereoProbedCalibration(
            ultrawide: uw,
            wide: wide,
            extrinsicsUWToWide: extrinsics,
            // Independent cross-check: the device-level factory transform from
            // `AVCaptureDevice.extrinsicMatrix(from: uw, to: wide)`, captured
            // before this photo probe. nil only when the SDK provided none.
            deviceExtrinsicsUWToWide: deviceExtrinsics,
            probedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
        resume(returning: stereo)
    }

    /// Extract the per-lens intrinsics/distortion from an `AVCameraCalibrationData`.
    /// Returns nil if focal lengths are missing or non-finite. Mirrors the mono
    /// extraction verbatim so the ultra-wide half is unchanged.
    private static func probedCalibration(from calibration: AVCameraCalibrationData,
                                          deviceModel: String) -> ProbedCameraCalibration? {
        let m = calibration.intrinsicMatrix
        let refDims = calibration.intrinsicMatrixReferenceDimensions
        let lookup = calibration.lensDistortionLookupTable ?? Data()
        let lookupFloats: [Float] = lookup.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
        // matrix_float3x3 is column-major:
        //   columns.0 = (fx, 0, 0), columns.1 = (0, fy, 0), columns.2 = (cx, cy, 1)
        let fx = Double(m.columns.0.x)
        let fy = Double(m.columns.1.y)
        let cx = Double(m.columns.2.x)
        let cy = Double(m.columns.2.y)
        guard fx > 0, fy > 0, fx.isFinite, fy.isFinite else {
            return nil
        }
        return ProbedCameraCalibration(
            fx: fx, fy: fy, cx: cx, cy: cy,
            referenceWidth: Int(refDims.width),
            referenceHeight: Int(refDims.height),
            lookupTableRadial: lookupFloats,
            distortionCenterX: Double(calibration.lensDistortionCenter.x),
            distortionCenterY: Double(calibration.lensDistortionCenter.y),
            deviceModel: deviceModel
        )
    }

    private func resume(returning value: StereoProbedCalibration) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    private func resume(throwing error: ProbeError) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

#endif // canImport(AVFoundation) && os(iOS)
