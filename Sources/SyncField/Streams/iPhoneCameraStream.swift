// Sources/SyncField/Streams/iPhoneCameraStream.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Video codec the iPhone camera stream encodes into. Exposed as a plain enum
/// so callers don't need to pull `AVFoundation` into their build when they're
/// constructing a `VideoSettings` literal.
public enum VideoCodec: String, Sendable {
    /// H.264 / AVC — broadly compatible, software-decoded on older devices.
    case h264 = "avc1"
    /// HEVC / H.265 — ~40 % smaller than H.264 at matched quality, requires
    /// hardware support on the decode side (standard on iOS 11+).
    case hevc = "hvc1"
}

/// Static metadata about the camera the stream selected, populated once
/// `configureSession` completes. Hosts use this to write a FOV-based
/// `camera_intrinsics.json` fallback before any frames arrive.
public struct ActiveCameraMetadata: Sendable {
    public let deviceTypeRawValue: String
    public let deviceLocalizedName: String
    public let activeFormatWidth: Int
    public let activeFormatHeight: Int
    public let fieldOfViewDegrees: Double
}

/// Values extracted from a single `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
/// attachment. Delivered to `setIntrinsicMatrixHandler` once per frame that
/// carries the attachment. `sampleWidth/sampleHeight` are the dimensions of
/// the pixel buffer the matrix is calibrated against — usually equals the
/// active format dimensions, but can differ if the buffer goes through a
/// scale pass.
public struct DeliveredCameraIntrinsics: Sendable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let frameIndex: Int
}

/// Output-file settings for `iPhoneCameraStream`.
///
/// Defaults reproduce the v0.2.9 behaviour (1920×1080 H.264). The struct is
/// backward-compatible — existing call sites that pass nothing still get the
/// same output they did before v0.2.10.
public struct VideoSettings: Sendable {
    public let width: Int
    public let height: Int
    public let codec: VideoCodec
    /// Optional average bitrate in bits-per-second. `nil` lets the encoder
    /// pick the default for the codec/size, which is usually fine. Set an
    /// explicit value when you need predictable file sizes.
    public let bitrate: Int?
    /// Target frame rate. If the device doesn't support this fps at the
    /// requested (width, height), `iPhoneCameraStream` falls back to the
    /// highest supported rate for that format — capture still succeeds.
    /// Default 30 preserves v0.2.10 behaviour for existing callers.
    public let fps: Int

    public init(
        width: Int,
        height: Int,
        codec: VideoCodec = .h264,
        bitrate: Int? = nil,
        fps: Int = 30
    ) {
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrate = bitrate
        self.fps = fps
    }

    /// 1280 × 720 H.264 @ 30 fps — smaller file than `.fullHD`, plenty of
    /// detail for hand-tracked egocentric capture.
    public static let hd720 = VideoSettings(width: 1280, height: 720, fps: 30)
    /// 1280 × 720 H.264 @ 60 fps — preferred for fast-motion egocentric
    /// tasks (pouring, handling tools) where motion blur matters.
    public static let hd720_60 = VideoSettings(width: 1280, height: 720, fps: 60)
    /// 1920 × 1080 H.264 @ 30 fps — legacy default used before v0.2.10.
    public static let fullHD = VideoSettings(width: 1920, height: 1080, fps: 30)
    /// 3840 × 2160 H.264 @ 30 fps — only on devices that expose a UHD back camera.
    public static let uhd4K = VideoSettings(width: 3840, height: 2160, fps: 30)
}

public final class iPhoneCameraStream: NSObject, SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true,
        supportsPreciseTimestamps: true,
        providesAudioTrack: true)

    private let videoSettings: VideoSettings

    #if canImport(AVFoundation)
    public let captureSession = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "syncfield.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var selectedVideoDevice: AVCaptureDevice?

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriterAudioInput: AVAssetWriterInput?
    private var isRecording = false

    private var stampWriter: StreamWriter?
    private var clock: SessionClock?
    private var frameCount = 0
    private var startPTS: CMTime = .zero

    private var healthBus: HealthBus?

    private var frameProcessor: ((@Sendable (CMSampleBuffer, Int) -> Void))?
    private var throttleHz: Double = 0
    private var lastProcessorCall: CFAbsoluteTime = 0

    /// Set via `setIntrinsicMatrixHandler`. Fires once per sample buffer that
    /// carries a `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
    /// attachment. Runs on the capture serial queue alongside the frame
    /// processor; do non-trivial work elsewhere.
    public typealias IntrinsicMatrixHandler =
        @Sendable (DeliveredCameraIntrinsics) -> Void
    private var intrinsicMatrixHandler: IntrinsicMatrixHandler?
    #endif

    /// Create a stream with the legacy 1080p output. Kept as an explicit
    /// convenience so existing call sites don't have to import `VideoSettings`.
    public convenience init(streamId: String) {
        self.init(streamId: streamId, videoSettings: .fullHD)
    }

    public init(streamId: String, videoSettings: VideoSettings) {
        self.streamId = streamId
        self.videoSettings = videoSettings
        super.init()
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if canImport(AVFoundation)
        try configureSession()
        captureSession.startRunning()
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    #if canImport(AVFoundation)
    /// Map the configured output size to the closest `AVCaptureSession.Preset`
    /// so the camera captures at the encoding resolution rather than at
    /// `.high` (which is typically 1080p on modern iPhones). Matching avoids
    /// an extra scale pass during encode and saves a meaningful chunk of
    /// battery on longer recordings.
    private var matchingCapturePreset: AVCaptureSession.Preset {
        switch (videoSettings.width, videoSettings.height) {
        case (640,  480):   return .vga640x480
        case (1280, 720):   return .hd1280x720
        case (1920, 1080):  return .hd1920x1080
        case (3840, 2160):  return .hd4K3840x2160
        default:            return .high
        }
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        // Commit + post-commit configuration (stabilization, intrinsics
        // delivery) run on `defer` so every early-exit path leaves the
        // session in a consistent state. The connection that
        // stabilization/intrinsics touch only exists after commit.
        defer {
            captureSession.commitConfiguration()
            disableVideoStabilization()
            enableCameraIntrinsicsDelivery()
        }

        captureSession.sessionPreset = matchingCapturePreset

        guard let device = Self.widestBackCamera() else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.Camera",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "back camera not available"]))
        }

        configureWidestFormatAndZoom(device: device)

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.Camera",
                                                  code: -2,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "back camera input cannot be added"]))
        }
        captureSession.addInput(input)
        selectedVideoDevice = device

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }
        }
        // If mic is unavailable (permissions, hardware) we fall through without audio.
    }

    /// Default-back-camera lookup that prefers the physical ultra-wide so
    /// recordings get the widest possible field of view — the right
    /// behaviour for egocentric / head-mounted capture, which is the SDK's
    /// primary use case. On devices without a dedicated ultra-wide
    /// (iPhone SE, X, 8 and earlier) `DiscoverySession` ranking falls back
    /// to the standard wide-angle camera, preserving the pre-0.9 behaviour
    /// on that hardware.
    private static func widestBackCamera() -> AVCaptureDevice? {
        #if os(iOS)
        if let ultraWide = AVCaptureDevice.default(
            .builtInUltraWideCamera,
            for: .video,
            position: .back
        ) {
            return ultraWide
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .back
        )

        return discovery.devices.sorted { lhs, rhs in
            let lhsRank = Self.devicePreferenceRank(lhs)
            let rhsRank = Self.devicePreferenceRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return Self.maximumFieldOfView(lhs) > Self.maximumFieldOfView(rhs)
        }.first
        #else
        // macOS: no ultra-wide / multi-lens variants exist; fall back to
        // the standard wide-angle pick that preserved the pre-0.9 SDK
        // behaviour.
        return AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        )
        #endif
    }

    private static func devicePreferenceRank(_ device: AVCaptureDevice) -> Int {
        #if os(iOS)
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return 0
        case .builtInDualWideCamera, .builtInTripleCamera:
            return 1
        case .builtInWideAngleCamera:
            return 2
        default:
            return 3
        }
        #else
        return 0
        #endif
    }

    private static func maximumFieldOfView(_ device: AVCaptureDevice) -> Float {
        #if os(iOS)
        return device.formats.map(\.videoFieldOfView).max()
            ?? device.activeFormat.videoFieldOfView
        #else
        return 0
        #endif
    }

    /// Pick the format with the widest `videoFieldOfView` on the active
    /// device, apply the requested fps as a frame-duration clamp, then lock
    /// the device to its minimum zoom factor — equivalent to 0.5× on a
    /// modern back-camera array. Both steps matter: a multi-lens device can
    /// expose several formats with different FOV (some cropped for
    /// stabilization headroom), and the minimum zoom factor floor is what
    /// keeps recording at the physical ultra-wide framing rather than the
    /// virtual-camera default which crops in.
    private func configureWidestFormatAndZoom(device: AVCaptureDevice) {
        #if os(iOS)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if let format = Self.widestUsableFormat(on: device, settings: videoSettings) {
                device.activeFormat = format
            }

            if let fps = Self.appliedFrameRate(for: device.activeFormat, targetFps: videoSettings.fps) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps.rounded()))))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }

            device.videoZoomFactor = device.minAvailableVideoZoomFactor
        } catch {
            NSLog("[SyncField.Camera] failed to configure widest FOV: \(error)")
        }
        #endif
    }

    private static func widestUsableFormat(
        on device: AVCaptureDevice,
        settings: VideoSettings
    ) -> AVCaptureDevice.Format? {
        let targetFps = Double(settings.fps)
        let requestedPixels = Int64(settings.width) * Int64(settings.height)
        let requestedAspect = Double(settings.width) / Double(settings.height)

        let fpsCompatible = device.formats.filter { format in
            supports(format: format, fps: targetFps)
        }
        let resolutionCompatible = fpsCompatible.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int64(dimensions.width) * Int64(dimensions.height) >= requestedPixels
        }
        let pool = !resolutionCompatible.isEmpty
            ? resolutionCompatible
            : (!fpsCompatible.isEmpty ? fpsCompatible : device.formats)

        return pool.max { lhs, rhs in
            #if os(iOS)
            let lhsFov = lhs.videoFieldOfView
            let rhsFov = rhs.videoFieldOfView
            if abs(lhsFov - rhsFov) > 0.1 {
                return lhsFov < rhsFov
            }
            #endif

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

    private static func supports(format: AVCaptureDevice.Format, fps: Double) -> Bool {
        guard fps > 0 else { return true }
        return format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= fps && range.maxFrameRate >= fps
        }
    }

    private static func appliedFrameRate(
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

    /// Re-apply the minimum-zoom floor. Called from `startRecording` as
    /// belt-and-braces: between session config and recording start an
    /// intervening subsystem (preview, system camera UI) can nudge zoom
    /// off its floor, which on a multi-lens device snaps capture back to
    /// the standard wide-angle framing.
    private func enforceMinimumZoom() {
        #if os(iOS)
        guard let device = selectedVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            device.unlockForConfiguration()
        } catch {
            NSLog("[SyncField.Camera] failed to enforce minimum zoom: \(error)")
        }
        #endif
    }

    /// Some stabilization modes (cinematic, standard) crop the sensor for
    /// headroom and silently narrow the effective FOV — undoing the work
    /// of selecting the widest format. Capture pipelines that want full
    /// FOV must turn it off explicitly; the AVFoundation default is
    /// non-zero on iPhone.
    private func disableVideoStabilization() {
        #if os(iOS)
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoStabilizationSupported else { return }
        connection.preferredVideoStabilizationMode = .off
        #endif
    }

    /// Ask AVFoundation to attach the per-frame `cameraIntrinsicMatrix`
    /// to each `CMSampleBuffer`. Without this opt-in the attachment is
    /// absent and downstream pipelines have no source of truth for fx/fy/
    /// cx/cy beyond an FOV-based estimate. Some formats / stabilization
    /// modes silently refuse the request — when that happens the property
    /// no-ops and `setIntrinsicMatrixHandler` simply never fires.
    private func enableCameraIntrinsicsDelivery() {
        #if os(iOS)
        guard let connection = videoOutput.connection(with: .video),
              connection.isCameraIntrinsicMatrixDeliverySupported else {
            return
        }
        connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        #endif
    }
    #endif

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        #if canImport(AVFoundation)
        // Re-assert capture configuration that can drift between
        // configureSession and the first frame: zoom-floor (intervening
        // subsystem nudges), stabilization-off (some session reconfigs
        // re-enable it), intrinsics delivery (toggled by format switches).
        enforceMinimumZoom()
        disableVideoStabilization()
        enableCameraIntrinsicsDelivery()

        self.clock = clock
        self.stampWriter = try writerFactory.makeStreamWriter(streamId: streamId)

        let url = writerFactory.videoURL(streamId: streamId)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType(rawValue: videoSettings.codec.rawValue),
            AVVideoWidthKey: videoSettings.width,
            AVVideoHeightKey: videoSettings.height,
        ]
        if let bitrate = videoSettings.bitrate {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 64000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        let newAudioInput: AVAssetWriterInput? =
            writer.canAdd(audioInput) ? { writer.add(audioInput); return audioInput }() : nil

        // Transition the writer to .writing BEFORE publishing state to the
        // sample-buffer delegate. Doing this on the writer's configuration
        // thread is fine — startWriting is synchronous and status flips before
        // it returns.
        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown"
            throw StreamError(
                streamId: streamId,
                underlying: NSError(
                    domain: "SyncField.Camera", code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "AVAssetWriter.startWriting() failed: \(reason)"]))
        }

        // Publish all recording state to the delegate in one go, ON videoQueue.
        // The delegate runs on this queue, so any callback dispatched here is
        // serialised with our setup — eliminating the write-order race that
        // produced:
        //   *** -[AVAssetWriter startSessionAtSourceTime:]
        //       Cannot call method when status is 0
        videoQueue.sync {
            self.frameCount = 0
            self.startPTS = .zero
            self.assetWriter = writer
            self.assetWriterInput = input
            self.assetWriterAudioInput = newAudioInput
            self.isRecording = true
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if canImport(AVFoundation)
        // Flip isRecording off on videoQueue so any in-flight delegate call
        // either sees it true and completes cleanly, or sees it false and
        // returns — never a torn read between isRecording and the writer.
        var capturedWriter: AVAssetWriter?
        var capturedAudioInput: AVAssetWriterInput?
        var capturedVideoInput: AVAssetWriterInput?
        var capturedCount = 0
        videoQueue.sync {
            self.isRecording = false
            capturedWriter = self.assetWriter
            capturedAudioInput = self.assetWriterAudioInput
            capturedVideoInput = self.assetWriterInput
            capturedCount = self.frameCount
            self.assetWriter = nil
            self.assetWriterInput = nil
            self.assetWriterAudioInput = nil
        }
        capturedAudioInput?.markAsFinished()
        capturedVideoInput?.markAsFinished()
        if let w = capturedWriter, w.status == .writing {
            await withCheckedContinuation { cont in
                w.finishWriting { cont.resume() }
            }
        }
        try await stampWriter?.close()
        stampWriter = nil
        return StreamStopReport(streamId: streamId, frameCount: capturedCount, kind: "video")
        #else
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
        #endif
    }

    public func ingest(into dir: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).mp4",
                           frameCount: frameCount)
    }

    public func disconnect() async throws {
        #if canImport(AVFoundation)
        captureSession.stopRunning()
        selectedVideoDevice = nil
        #endif
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    // MARK: Frame processor hook

    #if canImport(AVFoundation)
    static func midpointCorrectedTimestampNs(
        ptsSeconds: Double,
        exposureSeconds: Double
    ) -> (captureNs: UInt64, rawPtsNs: UInt64) {
        let safeExposure = exposureSeconds.isFinite ? max(0.0, exposureSeconds) : 0.0
        let rawPtsNs = UInt64(max(0.0, ptsSeconds) * 1_000_000_000)
        let captureNs = UInt64(max(0.0, ptsSeconds + safeExposure / 2.0) * 1_000_000_000)
        return (captureNs, rawPtsNs)
    }

    private func currentExposureDurationSeconds() -> Double {
        #if os(iOS)
        return selectedVideoDevice?.exposureDuration.seconds ?? 0
        #else
        return 0
        #endif
    }

    public func setFrameProcessor(throttleHz: Double = 0,
                                  _ body: @escaping @Sendable (CMSampleBuffer, Int) -> Void) {
        self.throttleHz = throttleHz
        self.frameProcessor = body
    }

    /// Register a handler that receives the exact `cameraIntrinsicMatrix`
    /// AVFoundation attaches to each `CMSampleBuffer` when the connection
    /// supports it. Typically called once per recording to write a
    /// `camera_intrinsics.json` sidecar. The handler runs on the capture
    /// serial queue, so dispatch I/O elsewhere.
    public func setIntrinsicMatrixHandler(_ handler: @escaping IntrinsicMatrixHandler) {
        self.intrinsicMatrixHandler = handler
    }

    /// Static metadata about the device + format selected during
    /// `configureSession`. Available after `connect()` resolves. Hosts use
    /// this to compute an FOV-based intrinsics estimate before any frame
    /// with an attached matrix arrives.
    public var activeCameraMetadata: ActiveCameraMetadata? {
        guard let device = selectedVideoDevice else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )
        #if os(iOS)
        let fov = Double(device.activeFormat.videoFieldOfView)
        #else
        let fov = 0.0
        #endif
        return ActiveCameraMetadata(
            deviceTypeRawValue: device.deviceType.rawValue,
            deviceLocalizedName: device.localizedName,
            activeFormatWidth: Int(dimensions.width),
            activeFormatHeight: Int(dimensions.height),
            fieldOfViewDegrees: fov
        )
    }
    #endif
}

#if canImport(AVFoundation)
extension iPhoneCameraStream: AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // This delegate fires on videoQueue, same queue we publish state on.
        // Any observed state here was fully visible after startRecording's
        // videoQueue.sync block returned. No need for additional locks.

        // Audio path — only forward once the writer is actually in .writing
        // AND the session has begun (first video frame stamped the source
        // time). Audio buffers that arrive before the first video frame are
        // dropped on purpose; otherwise appending audio before startSession
        // traps with the same "status is 0" exception as video.
        if output is AVCaptureAudioDataOutput {
            guard isRecording,
                  let writer = assetWriter,
                  writer.status == .writing,
                  startPTS != .zero,
                  let audioInput = assetWriterAudioInput,
                  audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            return
        }

        // Frame processor (throttled) — runs whether or not we're recording
        // so previews keep working during preview-only phases.
        if let processor = frameProcessor {
            let now = CFAbsoluteTimeGetCurrent()
            let interval = throttleHz > 0 ? 1.0 / throttleHz : 0
            if now - lastProcessorCall >= interval {
                processor(sampleBuffer, frameCount)
                lastProcessorCall = now
            }
        }

        // Camera-intrinsic matrix delivery. Independent of frame processor
        // and recording state so a host can capture intrinsics during
        // preview as well.
        if let handler = intrinsicMatrixHandler,
           let values = Self.intrinsicValues(from: sampleBuffer, frameIndex: frameCount) {
            handler(values)
        }

        // Recording path — guard on writer.status explicitly. Even though
        // state publishing is serialised on this same queue, a second call
        // could flip isRecording off between `isRecording` and
        // `writer.startSession` reads if cancellation lands. The status
        // check catches that without risking the startSession crash.
        guard isRecording,
              let writer = assetWriter,
              writer.status == .writing,
              let input = assetWriterInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .zero {
            // Belt-and-braces: re-check status immediately before the call
            // that failed in the wild. A release-mode reader could have
            // been reordered otherwise.
            guard writer.status == .writing else { return }
            startPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            // PTS is already in the monotonic host-clock domain on iOS (via the
            // CMClockGetHostTimeClock). AVFoundation PTS is effectively the
            // exposure start; VIO wants the optical midpoint, so shift by
            // half of the active exposure duration.
            let stamp = Self.midpointCorrectedTimestampNs(
                ptsSeconds: CMTimeGetSeconds(pts),
                exposureSeconds: currentExposureDurationSeconds()
            )
            let frame = frameCount
            frameCount += 1
            let w = stampWriter
            Task {
                try? await w?.append(frame: frame,
                                     monotonicNs: stamp.captureNs,
                                     uncertaintyNs: 1_000_000)
            }
        }
    }
}

extension iPhoneCameraStream {
    /// Pull the per-frame intrinsics off a sample buffer. AVFoundation
    /// surfaces the attachment in several places depending on iOS version
    /// (sample buffer key, sample attachments array, image-buffer
    /// attachment); we check all three. The raw payload is 9 packed
    /// Float32 values in column-major order.
    static func intrinsicValues(
        from sampleBuffer: CMSampleBuffer,
        frameIndex: Int
    ) -> DeliveredCameraIntrinsics? {
        guard let rawAttachment = cameraIntrinsicAttachment(from: sampleBuffer) else {
            return nil
        }
        let attachmentData: Data?
        if let data = rawAttachment as? Data {
            attachmentData = data
        } else if let data = rawAttachment as? NSData {
            attachmentData = data as Data
        } else {
            return nil
        }
        guard let data = attachmentData,
              let parsed = parseIntrinsicMatrixData(data) else { return nil }

        let (sampleWidth, sampleHeight): (Int, Int)
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            sampleWidth = CVPixelBufferGetWidth(imageBuffer)
            sampleHeight = CVPixelBufferGetHeight(imageBuffer)
        } else {
            sampleWidth = 0
            sampleHeight = 0
        }

        return DeliveredCameraIntrinsics(
            fx: parsed.fx, fy: parsed.fy, cx: parsed.cx, cy: parsed.cy,
            sampleWidth: sampleWidth,
            sampleHeight: sampleHeight,
            frameIndex: frameIndex
        )
    }

    /// Parse the raw 9-Float32 column-major payload AVFoundation stores
    /// in `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`. Exposed
    /// to the SDK module for unit testing without an `AVCaptureSession`.
    static func parseIntrinsicMatrixData(
        _ data: Data
    ) -> (fx: Double, fy: Double, cx: Double, cy: Double)? {
        let floats: [Float] = data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            guard buf.count >= 9 else { return [] }
            return Array(buf.prefix(9))
        }
        guard floats.count == 9 else { return nil }
        let fx = Double(floats[0])
        let fy = Double(floats[4])
        let cx = Double(floats[6])
        let cy = Double(floats[7])
        guard fx.isFinite, fy.isFinite, cx.isFinite, cy.isFinite,
              fx > 0, fy > 0 else { return nil }
        return (fx, fy, cx, cy)
    }

    private static func cameraIntrinsicAttachment(
        from sampleBuffer: CMSampleBuffer
    ) -> Any? {
        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) {
            return attachment
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
           let first = attachments.first,
           let attachment = first[kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix] {
            return attachment
        }
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let attachment = CVBufferGetAttachment(
            imageBuffer,
            kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            nil
        ) {
            return attachment
        }
        return nil
    }
}
#endif
