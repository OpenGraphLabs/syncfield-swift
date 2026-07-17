// Sources/SyncField/Streams/MultiCamCameraStream.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Emitted to `MultiCamCameraStream.setStereoDegradationHandler` when the
/// wide leg of the stereo pair stops mid-episode (iOS dropped the secondary
/// camera under system pressure, an interruption, or the wide output simply
/// stopped delivering) while the ultra-wide leg keeps recording. The host app
/// persists it alongside the manifest so downstream tooling knows exactly
/// where `cam_ego_wide` was truncated. Pure value type — no AVFoundation — so
/// it round-trips on any platform.
public struct StereoDegradationEvent: Codable, Equatable, Sendable {
    /// `capture_ns` of the last wide frame recorded before the leg was
    /// declared dead — the same value written as the wide entry's
    /// `truncated_at_ns`, so it lines up with `cam_ego_wide.timestamps.jsonl`.
    public let atNs: UInt64
    /// The stream that degraded — always `"cam_ego_wide"` for this stream.
    public let stream: String
    /// Stable snake_case cause, e.g. `"system_pressure_shutdown"`,
    /// `"session_interruption"`, `"wide_frames_stopped"`.
    public let reason: String

    public init(atNs: UInt64, stream: String, reason: String) {
        self.atNs = atNs
        self.stream = stream
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case atNs = "at_ns"
        case stream
        case reason
    }
}

/// Hardware-paired stereo capture: ultra-wide (`cam_ego`, contract-frozen) and
/// wide (`cam_ego_wide`) recorded simultaneously from one
/// `AVCaptureMultiCamSession`. Mirrors `iPhoneCameraStream`'s per-camera lens
/// policy, timestamp schema, and writer state machine exactly, adding a second
/// leg plus a degradation path: if the wide leg dies mid-episode the session,
/// ultra-wide writer, and audio keep running and the wide manifest entry is
/// marked `status:"truncated"`.
///
/// Threading model:
/// - The `AVCaptureDataOutputSynchronizer` delivers UW + wide + audio on ONE
///   serial queue (`syncQueue`). All AVAssetWriter mutation (startSession,
///   append, finish) and the wide-frame watchdog live in that domain, exactly
///   like `iPhoneCameraStream`'s `videoQueue`.
/// - Reporting + degradation facts (`uwFrameCount`, `wideFrameCount`,
///   `wideDegraded`, `wideTruncatedAtNs`) are pure-Swift state guarded by
///   `stateLock` so they are readable from `manifestEntries` (nonisolated,
///   off-queue).
/// - Degradation has ONE detector: the wide-frame watchdog on `syncQueue`
///   (fires only when the UW leg is still delivering while the wide leg has
///   gone silent). KVO `systemPressureState` + session interruption/runtime
///   notifications are diagnostic-only — they log and drop an attribution hint
///   onto `syncQueue`, but never mark truncation themselves, so a whole-session
///   stall can't produce a false wide truncation. The watchdog calls
///   `markWideDegraded`, which hops the wide-writer teardown onto `syncQueue`.
public final class MultiCamCameraStream: NSObject, SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let wideStreamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true,
        supportsPreciseTimestamps: true, providesAudioTrack: true)

    private let videoSettings: VideoSettings

    /// Static device/format metadata for the ULTRA-WIDE (`cam_ego`) leg,
    /// mirroring `iPhoneCameraStream.activeCameraMetadata` exactly (device type,
    /// active-format dimensions, field of view, GDC state). Available after
    /// `connect()` has selected the constituent devices. The host uses this to
    /// write the FOV-estimate tier of `camera_intrinsics.json` for the
    /// ultra-wide leg when no factory probe is present, so the frozen intrinsics
    /// contract is satisfied on stereo devices exactly as on mono ones. `nil`
    /// before `connect()` and on non-iOS platforms (multicam is iOS-only).
    public var activeCameraMetadata: ActiveCameraMetadata? {
        #if os(iOS) && canImport(AVFoundation)
        guard let device = uwDevice else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription)
        let fov = Double(device.activeFormat.videoFieldOfView)
        let gdc = device.isGeometricDistortionCorrectionSupported
            ? device.isGeometricDistortionCorrectionEnabled
            : true
        return ActiveCameraMetadata(
            deviceTypeRawValue: device.deviceType.rawValue,
            deviceLocalizedName: device.localizedName,
            activeFormatWidth: Int(dimensions.width),
            activeFormatHeight: Int(dimensions.height),
            fieldOfViewDegrees: fov,
            gdcEnabled: gdc
        )
        #else
        return nil
        #endif
    }

    /// Static device/format metadata for the WIDE (`cam_ego_wide`) leg,
    /// mirroring `activeCameraMetadata` exactly with the same post-configuration
    /// semantics (device type, active-format dimensions, field of view, actual
    /// GDC state). The host uses this to write the WIDE leg's FOV-estimate
    /// intrinsics + honest per-leg `gdc_enabled` into `cam_ego.calibration.json`
    /// (spec §5.1). `nil` before `connect()` and on non-iOS platforms.
    public var wideActiveCameraMetadata: ActiveCameraMetadata? {
        #if os(iOS) && canImport(AVFoundation)
        guard let device = wideDevice else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription)
        let fov = Double(device.activeFormat.videoFieldOfView)
        let gdc = device.isGeometricDistortionCorrectionSupported
            ? device.isGeometricDistortionCorrectionEnabled
            : true
        return ActiveCameraMetadata(
            deviceTypeRawValue: device.deviceType.rawValue,
            deviceLocalizedName: device.localizedName,
            activeFormatWidth: Int(dimensions.width),
            activeFormatHeight: Int(dimensions.height),
            fieldOfViewDegrees: fov,
            gdcEnabled: gdc
        )
        #else
        return nil
        #endif
    }

    /// Device-level factory extrinsics for the ultra-wide → wide physical pair,
    /// decoded from `AVCaptureDevice.extrinsicMatrix(from: uwDevice, to: wideDevice)`
    /// (iOS 13+). No photo capture and no running session — just the two
    /// physical devices, resolved from this stream's connected constituents when
    /// available, otherwise the default back UW/wide cameras (the same physical
    /// devices the support gate checks), so this is callable pre-`connect()`
    /// (e.g. the diagnostics harness). Returns `nil` when the SDK provides no
    /// factory calibration (virtual cameras / devices without one) — an honest
    /// "not available", never a substituted value. Always `nil` on non-iOS.
    public func stereoExtrinsics() -> StereoExtrinsics? {
        #if os(iOS) && canImport(AVFoundation)
        let uw = uwDevice ?? Self.ultrawideDevice()
        let wide = wideDevice ?? Self.wideDevice()
        return Self.deviceStereoExtrinsics(uwDevice: uw, wideDevice: wide)
        #else
        return nil
        #endif
    }

    // MARK: Reporting + degradation state (pure, cross-thread via stateLock)

    private let stateLock = NSLock()
    private var uwFrameCount = 0
    private var wideFrameCount = 0
    private var wideDegraded = false
    private var wideTruncatedAtNs: UInt64?
    private var stereoDegradationHandler: ((StereoDegradationEvent) -> Void)?

    private var healthBus: HealthBus?

    /// Per-leg manifest capabilities. UW carries the audio track; wide is
    /// video-only (global constraint: no audio on `cam_ego_wide`).
    private static let uwCapabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true,
        supportsPreciseTimestamps: true, providesAudioTrack: true)
    private static let wideCapabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true,
        supportsPreciseTimestamps: true, providesAudioTrack: false)

    // MARK: AVFoundation capture machinery (iOS only — multicam is iOS-only)

    #if os(iOS) && canImport(AVFoundation)
    private let multiCamSession = AVCaptureMultiCamSession()
    /// The single serial domain for every synchronized sample + writer mutation.
    private let syncQueue = DispatchQueue(label: "syncfield.multicam.sync", qos: .userInitiated)

    private var uwDevice: AVCaptureDevice?
    private var wideDevice: AVCaptureDevice?
    private var uwInput: AVCaptureDeviceInput?
    private var wideInput: AVCaptureDeviceInput?
    private let uwVideoOutput = AVCaptureVideoDataOutput()
    private let wideVideoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var uwConnection: AVCaptureConnection?
    private var wideConnection: AVCaptureConnection?
    private var synchronizer: AVCaptureDataOutputSynchronizer?

    // Writers — mutated only on syncQueue.
    private var uwWriter: AVAssetWriter?
    private var uwVideoInput: AVAssetWriterInput?
    private var uwAudioInput: AVAssetWriterInput?
    private var wideWriter: AVAssetWriter?
    private var wideVideoInput: AVAssetWriterInput?
    private var uwStampWriter: StreamWriter?
    private var wideStampWriter: StreamWriter?

    private var isRecording = false
    private var uwStartPTS: CMTime = .zero
    private var wideStartPTS: CMTime = .zero

    // Frame processor (UW frames only), same drop-on-busy gate as the mono stream.
    private var frameProcessor: (@Sendable (CMSampleBuffer, Int) -> Void)?
    private var throttleHz: Double = 0
    private var lastProcessorCall: CFAbsoluteTime = 0
    private let processorGate = FrameProcessorGate(label: "syncfield.multicam.processor")

    // Degradation detection.
    private var uwPressureObservation: NSKeyValueObservation?
    private var widePressureObservation: NSKeyValueObservation?
    private var wideWatchdog: DispatchSourceTimer?
    private var lastUWFrameHostTime: CFAbsoluteTime = 0
    private var lastWideFrameHostTime: CFAbsoluteTime = 0
    /// capture_ns (monotonic, midpoint-corrected) of the most recent wide
    /// frame actually appended — syncQueue-confined. Becomes `truncated_at_ns`
    /// when the watchdog declares the wide leg dead, so the truncation point
    /// matches a real line in `cam_ego_wide.timestamps.jsonl` rather than the
    /// (later) detection instant.
    private var lastWideCaptureNs: UInt64 = 0
    /// Attribution hint set by the KVO/interruption/runtime-error handlers via
    /// a syncQueue hop so the watchdog — the SOLE degradation detector — can
    /// name the cause. `nil` ⇒ `"wide_frames_stopped"`. syncQueue-confined.
    private var pendingWideDegradeReasonHint: String?
    /// Tracks the wide writer's async `finishWriting` when a mid-episode
    /// degradation finalizes it, so `stopRecording` can await completion and
    /// never race an unfinalized moov. Thread-safe primitive — no confinement.
    private let wideFinalizeGroup = DispatchGroup()

    /// How long the wide leg may be silent while the UW leg keeps delivering
    /// before we declare the wide leg dead. 1.5s absorbs a slow first frame
    /// and brief reconfiguration windows while still catching a real drop
    /// within one extra tick.
    private static let wideStallThresholdSeconds: Double = 1.5

    /// Ultra-wide dimensions/fps the frozen `cam_ego` contract requires; the
    /// static support gate checks the pair can sustain exactly this.
    #endif

    // MARK: Init

    public init(
        streamId: String = "cam_ego",
        wideStreamId: String = "cam_ego_wide",
        videoSettings: VideoSettings
    ) {
        self.streamId = streamId
        self.wideStreamId = wideStreamId
        self.videoSettings = videoSettings
        super.init()
    }

    // MARK: Support gate (pure result; non-iOS ⇒ always unsupported)

    /// `true` only when: multicam is supported, both physical back cameras
    /// exist, the (UW, wide) pair is in some `supportedMultiCamDeviceSets`,
    /// AND both devices expose a multicam-capable 1080p30 format. Pure check —
    /// no session is created.
    public static func isSupported() -> Bool { unsupportedReason() == nil }

    /// First failing support check as a stable snake_case string, or `nil`
    /// when fully supported. The host forwards this to telemetry.
    public static func unsupportedReason() -> String? {
        #if os(iOS) && canImport(AVFoundation)
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            return "multicam_unsupported"
        }
        guard let uw = ultrawideDevice() else { return "ultrawide_device_missing" }
        guard let wide = wideDevice() else { return "wide_device_missing" }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        let pairSupported = discovery.supportedMultiCamDeviceSets.contains { set in
            set.contains(uw) && set.contains(wide)
        }
        guard pairSupported else { return "device_set_pair_unavailable" }

        // Strict 1080p30 predicate — deliberately NOT widestUsableFormat,
        // which falls back to any multicam format (A4 review flag 1).
        let bothCan = CameraDeviceConfig.hasMultiCamFormat(
                on: uw, minWidth: 1920, minHeight: 1080, fps: 30)
            && CameraDeviceConfig.hasMultiCamFormat(
                on: wide, minWidth: 1920, minHeight: 1080, fps: 30)
        guard bothCan else { return "format_1080p30_unavailable" }
        return nil
        #else
        return "multicam_unsupported"
        #endif
    }

    #if os(iOS) && canImport(AVFoundation)
    private static func ultrawideDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    }
    private static func wideDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Decodes the ultra-wide → wide device-level factory extrinsics for the
    /// two given physical devices via `AVCaptureDevice.extrinsicMatrix(from:to:)`.
    /// Public so a host-side diagnostics harness that already holds the two
    /// devices can read the same value the recording path writes, without
    /// reaching the module-internal decode math. Returns `nil` if either device
    /// is missing or the SDK provides no factory matrix.
    public static func deviceStereoExtrinsics(
        uwDevice: AVCaptureDevice?, wideDevice: AVCaptureDevice?
    ) -> StereoExtrinsics? {
        guard let uwDevice, let wideDevice,
              let matrixData = AVCaptureDevice.extrinsicMatrix(from: uwDevice, to: wideDevice)
        else { return nil }
        return StereoExtrinsicsMath.directExtrinsics(fromMatrixData: matrixData)
    }

    /// The multicam session, exposed for preview reuse (host wires it to an
    /// `AVCaptureVideoPreviewLayer`, one connection per leg).
    public var captureSession: AVCaptureSession { multiCamSession }
    #endif

    // MARK: Degradation (pure — usable & unit-testable without a device)

    public func setStereoDegradationHandler(_ handler: @escaping (StereoDegradationEvent) -> Void) {
        stateLock.lock()
        stereoDegradationHandler = handler
        stateLock.unlock()
    }

    /// Declare the wide leg dead. Idempotent: the first call wins (its
    /// timestamp/reason are the ones reported and the only event emitted).
    /// Sets the pure reporting facts under `stateLock`, fires the host
    /// handler once (outside the lock), then — on iOS — finalizes the wide
    /// writer cleanly on `syncQueue`. Internal (not public) so tests can
    /// drive the truncation path on macOS.
    func markWideDegraded(atNs: UInt64, reason: String) {
        stateLock.lock()
        if wideDegraded {
            stateLock.unlock()
            return
        }
        wideDegraded = true
        wideTruncatedAtNs = atNs
        let handler = stereoDegradationHandler
        stateLock.unlock()

        handler?(StereoDegradationEvent(atNs: atNs, stream: wideStreamId, reason: reason))

        #if os(iOS) && canImport(AVFoundation)
        finalizeWideWriterAfterDegradation()
        #endif
    }

    // MARK: Manifest

    public nonisolated func manifestEntries(report: StreamIngestReport?) -> [Manifest.StreamEntry] {
        stateLock.lock()
        let uw = uwFrameCount
        let wide = wideFrameCount
        let degraded = wideDegraded
        let truncatedAtNs = wideTruncatedAtNs
        stateLock.unlock()

        let uwEntry = Manifest.StreamEntry(
            streamId: streamId,
            filePath: SessionOrchestrator.defaultFilePath(streamId: streamId, kind: "video"),
            frameCount: report?.frameCount ?? uw,
            kind: "video",
            capabilities: Self.uwCapabilities,
            syncGroupId: streamId)

        let wideEntry = Manifest.StreamEntry(
            streamId: wideStreamId,
            filePath: SessionOrchestrator.defaultFilePath(streamId: wideStreamId, kind: "video"),
            frameCount: wide,
            kind: "video",
            capabilities: Self.wideCapabilities,
            syncGroupId: streamId,
            status: degraded ? "truncated" : nil,
            truncatedAtNs: degraded ? truncatedAtNs : nil)

        return [uwEntry, wideEntry]
    }

    // MARK: Lifecycle

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if os(iOS) && canImport(AVFoundation)
        try configureSession()
        multiCamSession.startRunning()
        await healthBus?.publish(.streamConnected(streamId: streamId))
        #else
        throw StreamError(
            streamId: streamId,
            underlying: SessionError.deviceUnsupported(
                reason: Self.unsupportedReason() ?? "multicam_unsupported"))
        #endif
    }

    public func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {
        #if os(iOS) && canImport(AVFoundation)
        // Re-assert config that can drift between configureSession and the
        // first frame (mirrors iPhoneCameraStream): zoom floor, stabilization
        // off, intrinsics delivery, GDC off — for BOTH devices/connections.
        enforceMinimumZoom()
        configureVideoConnections()
        disableGDC()
        // Note: `clock` is intentionally not stored. Truncation timestamps come
        // from the wide leg's own last capture_ns (see `lastWideCaptureNs`), and
        // no other code path needs a session clock off the syncQueue — so there
        // is no shared `clock` field for KVO/notification threads to race on.

        // UW writer: video + audio, exactly like iPhoneCameraStream cam_ego.
        let uwStamp = try writerFactory.makeStreamWriter(streamId: streamId)
        let uwURL = writerFactory.videoURL(streamId: streamId)
        try? FileManager.default.removeItem(at: uwURL)
        let uwW = try AVAssetWriter(outputURL: uwURL, fileType: .mp4)
        let uwVInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings())
        uwVInput.expectsMediaDataInRealTime = true
        uwW.add(uwVInput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings())
        audioInput.expectsMediaDataInRealTime = true
        let uwAInput: AVAssetWriterInput? =
            uwW.canAdd(audioInput) ? { uwW.add(audioInput); return audioInput }() : nil
        guard uwW.startWriting() else {
            throw startWritingError(writer: uwW, streamId: streamId)
        }

        // Wide writer: video only (no audio track on cam_ego_wide).
        let wideStamp = try writerFactory.makeStreamWriter(streamId: wideStreamId)
        let wideURL = writerFactory.videoURL(streamId: wideStreamId)
        try? FileManager.default.removeItem(at: wideURL)
        let wideW = try AVAssetWriter(outputURL: wideURL, fileType: .mp4)
        let wideVInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings())
        wideVInput.expectsMediaDataInRealTime = true
        wideW.add(wideVInput)
        guard wideW.startWriting() else {
            throw startWritingError(writer: wideW, streamId: wideStreamId)
        }

        // Publish recording state on syncQueue so the synchronizer delegate
        // and watchdog (which run there) observe a fully-formed setup.
        syncQueue.sync {
            self.resetCountersForNewRecording()
            self.uwStartPTS = .zero
            self.wideStartPTS = .zero
            self.uwWriter = uwW
            self.uwVideoInput = uwVInput
            self.uwAudioInput = uwAInput
            self.uwStampWriter = uwStamp
            self.wideWriter = wideW
            self.wideVideoInput = wideVInput
            self.wideStampWriter = wideStamp
            self.lastWideCaptureNs = 0
            self.pendingWideDegradeReasonHint = nil
            let now = CFAbsoluteTimeGetCurrent()
            self.lastUWFrameHostTime = now
            self.lastWideFrameHostTime = now
            self.isRecording = true
            self.startWideWatchdogOnSyncQueue()
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if os(iOS) && canImport(AVFoundation)
        var uwW: AVAssetWriter?
        var uwVInput: AVAssetWriterInput?
        var uwAInput: AVAssetWriterInput?
        var wideW: AVAssetWriter?
        var wideVInput: AVAssetWriterInput?
        var uwStamp: StreamWriter?
        var wideStamp: StreamWriter?
        var uwCount = 0

        // Flip isRecording off and transfer ownership of every writer out of
        // the syncQueue domain in one barrier. A late synchronized-collection
        // callback then sees isRecording=false / nil writers and no-ops.
        syncQueue.sync {
            self.isRecording = false
            uwW = self.uwWriter; uwVInput = self.uwVideoInput; uwAInput = self.uwAudioInput
            wideW = self.wideWriter; wideVInput = self.wideVideoInput
            uwStamp = self.uwStampWriter; wideStamp = self.wideStampWriter
            self.uwWriter = nil; self.uwVideoInput = nil; self.uwAudioInput = nil
            self.wideWriter = nil; self.wideVideoInput = nil
            self.uwStampWriter = nil; self.wideStampWriter = nil
            self.wideWatchdog?.cancel(); self.wideWatchdog = nil
            self.stateLock.lock()
            uwCount = self.uwFrameCount
            self.stateLock.unlock()
        }
        processorGate.drain()

        uwAInput?.markAsFinished()
        uwVInput?.markAsFinished()
        if let w = uwW, w.status == .writing {
            await withCheckedContinuation { cont in w.finishWriting { cont.resume() } }
        }
        // Wide leg: exactly one of two paths finalizes the moov.
        //  - No degradation: this barrier captured a live wideWriter → finish
        //    it here (awaited).
        //  - Mid-episode degradation: finalizeWideWriterAfterDegradation()
        //    already took the writer (wideW == nil here) and kicked off its
        //    async finishWriting under wideFinalizeGroup → await that group so
        //    teardown never races an unfinalized moov.
        wideVInput?.markAsFinished()
        if let w = wideW, w.status == .writing {
            await withCheckedContinuation { cont in w.finishWriting { cont.resume() } }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wideFinalizeGroup.notify(queue: syncQueue) { cont.resume() }
        }
        try await uwStamp?.close()
        try await wideStamp?.close()

        return StreamStopReport(streamId: streamId, frameCount: uwCount, kind: "video")
        #else
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
        #endif
    }

    public func ingest(into episodeDirectory: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        // Read the counter through the synchronous helper so the lock is never
        // taken directly in this async context (NSLock.lock() is unavailable
        // from async in the Swift 6 language mode).
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).mp4",
                           frameCount: peekUWFrameCount())
    }

    public func disconnect() async throws {
        #if os(iOS) && canImport(AVFoundation)
        multiCamSession.stopRunning()
        processorGate.drain()
        uwPressureObservation?.invalidate(); uwPressureObservation = nil
        widePressureObservation?.invalidate(); widePressureObservation = nil
        NotificationCenter.default.removeObserver(self)
        synchronizer = nil
        uwDevice = nil
        wideDevice = nil
        #endif
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    // MARK: Frame processor (UW only)

    #if os(iOS) && canImport(AVFoundation)
    public func setFrameProcessor(
        throttleHz: Double = 0,
        _ body: @escaping @Sendable (CMSampleBuffer, Int) -> Void
    ) {
        self.throttleHz = throttleHz
        self.frameProcessor = body
    }
    #endif

    private func resetCountersForNewRecording() {
        stateLock.lock()
        uwFrameCount = 0
        wideFrameCount = 0
        wideDegraded = false
        wideTruncatedAtNs = nil
        stateLock.unlock()
    }

    private func peekUWFrameCount() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return uwFrameCount
    }

    private func nextUWFrameIndex() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        let idx = uwFrameCount; uwFrameCount += 1; return idx
    }

    private func nextWideFrameIndex() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        let idx = wideFrameCount; wideFrameCount += 1; return idx
    }

    private func isWideDegradedSnapshot() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return wideDegraded
    }
}

// MARK: - AVFoundation session configuration + capture (iOS only)

#if os(iOS) && canImport(AVFoundation)
extension MultiCamCameraStream {
    private func configureSession() throws {
        if let reason = Self.unsupportedReason() {
            throw StreamError(streamId: streamId,
                              underlying: SessionError.deviceUnsupported(reason: reason))
        }
        guard let uw = Self.ultrawideDevice(), let wide = Self.wideDevice() else {
            throw StreamError(streamId: streamId,
                              underlying: SessionError.deviceUnsupported(
                                reason: "device_missing_at_configure"))
        }
        self.uwDevice = uw
        self.wideDevice = wide

        // Select each device's multicam 1080p30 activeFormat + fps + zoom
        // BEFORE wiring inputs, so the format is in place when the session
        // validates multicam hardware cost (mirrors the mono stream applying
        // its format before AVCaptureDeviceInput at iPhoneCameraStream:291).
        applyLensPolicies()

        multiCamSession.beginConfiguration()
        // Post-commit re-assertion of *connection*/device lens state only —
        // the format is already applied above. This defer runs on every exit
        // path (mirrors the mono stream's configureSession defer at
        // iPhoneCameraStream:272-277, which likewise re-asserts stabilization/
        // intrinsics/GDC/zoom post-commit but not the format).
        defer {
            multiCamSession.commitConfiguration()
            enforceMinimumZoom()
            configureVideoConnections()
            disableGDC()
        }

        // Inputs — multicam requires manual, no-automatic connections so each
        // physical camera is wired to its own output.
        let uwIn = try AVCaptureDeviceInput(device: uw)
        guard multiCamSession.canAddInput(uwIn) else {
            throw addFailure("ultrawide_input_not_addable")
        }
        multiCamSession.addInputWithNoConnections(uwIn)
        self.uwInput = uwIn

        let wideIn = try AVCaptureDeviceInput(device: wide)
        guard multiCamSession.canAddInput(wideIn) else {
            throw addFailure("wide_input_not_addable")
        }
        multiCamSession.addInputWithNoConnections(wideIn)
        self.wideInput = wideIn

        // Outputs — BGRA, drop-late (matches iPhoneCameraStream:304-307).
        configureVideoOutput(uwVideoOutput)
        guard multiCamSession.canAddOutput(uwVideoOutput) else {
            throw addFailure("ultrawide_output_not_addable")
        }
        multiCamSession.addOutputWithNoConnections(uwVideoOutput)

        configureVideoOutput(wideVideoOutput)
        guard multiCamSession.canAddOutput(wideVideoOutput) else {
            throw addFailure("wide_output_not_addable")
        }
        multiCamSession.addOutputWithNoConnections(wideVideoOutput)

        // Manual video connections: each input's video port → its own output.
        guard let uwPort = uwIn.ports(
                for: .video, sourceDeviceType: uw.deviceType,
                sourceDevicePosition: uw.position).first,
              let widePort = wideIn.ports(
                for: .video, sourceDeviceType: wide.deviceType,
                sourceDevicePosition: wide.position).first else {
            throw addFailure("video_port_unavailable")
        }
        let uwConn = AVCaptureConnection(inputPorts: [uwPort], output: uwVideoOutput)
        guard multiCamSession.canAddConnection(uwConn) else {
            throw addFailure("ultrawide_connection_not_addable")
        }
        multiCamSession.addConnection(uwConn)
        self.uwConnection = uwConn

        let wideConn = AVCaptureConnection(inputPorts: [widePort], output: wideVideoOutput)
        guard multiCamSession.canAddConnection(wideConn) else {
            throw addFailure("wide_connection_not_addable")
        }
        multiCamSession.addConnection(wideConn)
        self.wideConnection = wideConn

        // Audio → UW writer only. A single automatic connection is fine; the
        // synchronizer observes the output's samples all the same.
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioIn = try? AVCaptureDeviceInput(device: audioDevice),
           multiCamSession.canAddInput(audioIn) {
            multiCamSession.addInput(audioIn)
            if multiCamSession.canAddOutput(audioOutput) {
                multiCamSession.addOutput(audioOutput)
            }
        }
        // If the mic is unavailable we still record both video legs.

        // One synchronizer over [UW, wide, audio] on one serial queue. UW is
        // primary (first), so collections are keyed to UW frames.
        let sync = AVCaptureDataOutputSynchronizer(
            dataOutputs: [uwVideoOutput, wideVideoOutput, audioOutput])
        sync.setDelegate(self, queue: syncQueue)
        self.synchronizer = sync

        installDegradationObservers()
    }

    private func configureVideoOutput(_ output: AVCaptureVideoDataOutput) {
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        // No per-output sample delegate: the synchronizer owns delivery.
    }

    private func applyLensPolicies() {
        if let uw = uwDevice {
            CameraDeviceConfig.applyLensPolicy(uw, settings: videoSettings, requireMultiCam: true)
        }
        if let wide = wideDevice {
            CameraDeviceConfig.applyLensPolicy(wide, settings: videoSettings, requireMultiCam: true)
        }
    }

    /// Per-connection state: stabilization off (keeps full FOV) + intrinsics
    /// delivery on. Applied at configure and re-asserted at start.
    private func configureVideoConnections() {
        for connection in [uwConnection, wideConnection].compactMap({ $0 }) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }
    }

    private func disableGDC() {
        for device in [uwDevice, wideDevice].compactMap({ $0 }) {
            guard device.isGeometricDistortionCorrectionSupported else {
                NSLog("[SyncField.MultiCam] GDC toggle NOT supported on \(device.deviceType.rawValue)")
                continue
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.isGeometricDistortionCorrectionEnabled = false
            } catch {
                NSLog("[SyncField.MultiCam] failed to disable GDC on \(device.deviceType.rawValue): \(error)")
            }
        }
    }

    private func enforceMinimumZoom() {
        for device in [uwDevice, wideDevice].compactMap({ $0 }) {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = device.minAvailableVideoZoomFactor
                device.unlockForConfiguration()
            } catch {
                NSLog("[SyncField.MultiCam] failed to enforce minimum zoom on \(device.deviceType.rawValue): \(error)")
            }
        }
    }

    private func videoOutputSettings() -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType(rawValue: videoSettings.codec.rawValue),
            AVVideoWidthKey: videoSettings.width,
            AVVideoHeightKey: videoSettings.height,
        ]
        if let bitrate = videoSettings.bitrate {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate]
        }
        return settings
    }

    private func audioOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 64000,
        ]
    }

    private func addFailure(_ reason: String) -> StreamError {
        StreamError(streamId: streamId,
                    underlying: NSError(domain: "SyncField.MultiCam", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: reason]))
    }

    private func startWritingError(writer: AVAssetWriter, streamId: String) -> StreamError {
        let reason = writer.error?.localizedDescription ?? "unknown"
        return StreamError(
            streamId: streamId,
            underlying: NSError(domain: "SyncField.MultiCam", code: -3,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "AVAssetWriter.startWriting() failed: \(reason)"]))
    }
}

// MARK: - Degradation detection (KVO + notifications + wide-frame watchdog)

extension MultiCamCameraStream {
    private func installDegradationObservers() {
        if let uw = uwDevice {
            uwPressureObservation = uw.observe(\.systemPressureState, options: [.new]) {
                [weak self] device, _ in
                self?.handleSystemPressure(device: device, isWide: false)
            }
        }
        if let wide = wideDevice {
            widePressureObservation = wide.observe(\.systemPressureState, options: [.new]) {
                [weak self] device, _ in
                self?.handleSystemPressure(device: device, isWide: true)
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted, object: multiCamSession)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError, object: multiCamSession)
    }

    // KVO/notification handlers are DIAGNOSTIC-ONLY. They never mark the wide
    // leg truncated themselves — that decision belongs solely to the
    // wide-frame watchdog (uwFresh && wideStale), a single robust path that
    // (a) cannot fire spuriously on a whole-session/transient interruption
    // because it requires the UW leg to still be delivering, and (b) leaves a
    // real UW gap visible as a timestamp gap instead of a false truncation.
    // These handlers only record an attribution *hint* so the watchdog can
    // name the cause when it does fire.

    private func handleSystemPressure(device: AVCaptureDevice, isWide: Bool) {
        guard device.systemPressureState.level == .shutdown else { return }
        if isWide {
            NSLog("[SyncField.MultiCam] wide system pressure SHUTDOWN — watchdog will truncate cam_ego_wide")
            noteWideDegradeHint("system_pressure_shutdown")
        } else {
            // UW shutdown = whole-stream failure (existing mono semantics): the
            // primary leg can't be salvaged. Surface it; the short cam_ego.mp4
            // is reported by stopRecording as usual. Not a wide truncation.
            NSLog("[SyncField.MultiCam] ULTRA-WIDE system pressure SHUTDOWN — cam_ego capture failing")
            let hb = healthBus
            let sid = streamId
            Task { await hb?.publish(.streamDisconnected(streamId: sid, reason: "system_pressure_shutdown")) }
        }
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        guard let value = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: value) else { return }
        switch reason {
        case .videoDeviceNotAvailableDueToSystemPressure,
             .videoDeviceNotAvailableWithMultipleForegroundApps:
            // Under these, iOS reduces multicam hardware cost by dropping the
            // secondary (wide) camera while keeping UW + audio alive. Wide
            // frames stop, so the watchdog truncates; we only supply the cause.
            NSLog("[SyncField.MultiCam] session interrupted reason=\(reason.rawValue) — wide likely dropped, watchdog will truncate")
            noteWideDegradeHint("session_interruption")
        default:
            // Whole-session / transient interruption: UW stops too, so the
            // watchdog's uwFresh gate keeps it from raising a false truncation.
            NSLog("[SyncField.MultiCam] session interrupted reason=\(reason.rawValue) — whole-session, no wide truncation")
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        NSLog("[SyncField.MultiCam] runtime error: \(err?.localizedDescription ?? "unknown")")
        // A wide-only runtime failure manifests as the wide output going silent
        // — the watchdog catches it. A whole-session failure kills UW too (no
        // fallback, Jerry's rule); surface it and let stop report the files.
        noteWideDegradeHint("session_runtime_error")
        let hb = healthBus
        let sid = streamId
        Task { await hb?.publish(.streamDisconnected(streamId: sid, reason: "session_runtime_error")) }
    }

    /// Record a cause hint for the watchdog, confined to `syncQueue` (where the
    /// watchdog reads it). First hint wins so the earliest signal names the
    /// cause; a later generic signal never overwrites a specific one.
    private func noteWideDegradeHint(_ reason: String) {
        syncQueue.async { [weak self] in
            guard let self, self.pendingWideDegradeReasonHint == nil else { return }
            self.pendingWideDegradeReasonHint = reason
        }
    }

    /// Scheduled on `syncQueue`; reads the last-frame host times written by the
    /// synchronizer delegate on that same queue, so no lock is needed here.
    private func startWideWatchdogOnSyncQueue() {
        wideWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + Self.wideStallThresholdSeconds, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tickWideWatchdog() }
        wideWatchdog = timer
        timer.resume()
    }

    /// The SOLE degradation detector. Fires only when the UW leg is still
    /// delivering (uwFresh) AND the wide leg has gone silent (wideStale) — so a
    /// whole-session stall never produces a false wide truncation.
    private func tickWideWatchdog() {
        guard isRecording, !isWideDegradedSnapshot() else { return }
        // Only judge once the UW leg is genuinely flowing — otherwise a slow
        // whole-session start would look like a wide-only drop.
        guard uwStartPTS != .zero else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let uwFresh = (now - lastUWFrameHostTime) < Self.wideStallThresholdSeconds
        let wideStale = (now - lastWideFrameHostTime) >= Self.wideStallThresholdSeconds
        guard uwFresh, wideStale else { return }
        // truncated_at_ns = the last wide frame's own capture_ns (a real line in
        // cam_ego_wide.timestamps.jsonl), not this detection instant.
        let reason = pendingWideDegradeReasonHint ?? "wide_frames_stopped"
        markWideDegraded(atNs: lastWideCaptureNs, reason: reason)
    }

    /// Finish the wide writer cleanly on `syncQueue` after degradation, then
    /// clear its references so a concurrent `stopRecording` won't double-finish
    /// and the synchronizer delegate stops appending. Runs after any in-flight
    /// delegate call because `syncQueue` is serial.
    private func finalizeWideWriterAfterDegradation() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            guard let writer = self.wideWriter else { return }  // already finalized
            let input = self.wideVideoInput
            let stamp = self.wideStampWriter
            self.wideWriter = nil
            self.wideVideoInput = nil
            self.wideStampWriter = nil
            input?.markAsFinished()
            if writer.status == .writing {
                // Track completion so stopRecording can await it (fix 2): the
                // moov must be fully written before teardown proceeds.
                self.wideFinalizeGroup.enter()
                writer.finishWriting { [weak self] in
                    self?.wideFinalizeGroup.leave()
                }
            }
            if let stamp {
                Task { try? await stamp.close() }
            }
        }
    }
}

// MARK: - Synchronized capture delegate

extension MultiCamCameraStream: AVCaptureDataOutputSynchronizerDelegate {
    public func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        // Runs on syncQueue — the sole writer-mutation domain.
        if let uwData = synchronizedDataCollection.synchronizedData(for: uwVideoOutput)
            as? AVCaptureSynchronizedSampleBufferData, !uwData.sampleBufferWasDropped {
            handleUWSample(uwData.sampleBuffer)
        }
        if let wideData = synchronizedDataCollection.synchronizedData(for: wideVideoOutput)
            as? AVCaptureSynchronizedSampleBufferData, !wideData.sampleBufferWasDropped {
            handleWideSample(wideData.sampleBuffer)
        }
        if let audioData = synchronizedDataCollection.synchronizedData(for: audioOutput)
            as? AVCaptureSynchronizedSampleBufferData, !audioData.sampleBufferWasDropped {
            handleAudioSample(audioData.sampleBuffer)
        }
    }

    private func handleUWSample(_ sampleBuffer: CMSampleBuffer) {
        // Frame processor (UW only), throttled + drop-on-busy — identical
        // policy to iPhoneCameraStream so previews keep working pre-record.
        if let processor = frameProcessor {
            let now = CFAbsoluteTimeGetCurrent()
            let interval = throttleHz > 0 ? 1.0 / throttleHz : 0
            if now - lastProcessorCall >= interval {
                let snapshot = sampleBuffer
                let frameIndex = peekUWFrameCount()
                if processorGate.tryEnqueue({ processor(snapshot, frameIndex) }) {
                    lastProcessorCall = now
                }
            }
        }

        lastUWFrameHostTime = CFAbsoluteTimeGetCurrent()

        guard isRecording,
              let writer = uwWriter,
              writer.status == .writing,
              let input = uwVideoInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if uwStartPTS == .zero {
            guard writer.status == .writing else { return }
            uwStartPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
        let stamp = CameraTimestamps.midpointCorrectedTimestampNs(
            ptsSeconds: CMTimeGetSeconds(pts),
            exposureSeconds: uwDevice?.exposureDuration.seconds ?? 0)
        let frame = nextUWFrameIndex()
        let w = uwStampWriter
        Task {
            try? await w?.append(frame: frame, monotonicNs: stamp.captureNs, uncertaintyNs: 1_000_000)
        }
    }

    private func handleWideSample(_ sampleBuffer: CMSampleBuffer) {
        lastWideFrameHostTime = CFAbsoluteTimeGetCurrent()
        // Once the wide leg is declared dead we stop feeding its writer; the
        // watchdog + this guard both read the same flag.
        if isWideDegradedSnapshot() { return }

        guard isRecording,
              let writer = wideWriter,
              writer.status == .writing,
              let input = wideVideoInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if wideStartPTS == .zero {
            guard writer.status == .writing else { return }
            wideStartPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
        let stamp = CameraTimestamps.midpointCorrectedTimestampNs(
            ptsSeconds: CMTimeGetSeconds(pts),
            exposureSeconds: wideDevice?.exposureDuration.seconds ?? 0)
        // Remember this frame's capture_ns so a later watchdog truncation points
        // at a real cam_ego_wide.timestamps.jsonl line (syncQueue-confined).
        lastWideCaptureNs = stamp.captureNs
        let frame = nextWideFrameIndex()
        let w = wideStampWriter
        Task {
            try? await w?.append(frame: frame, monotonicNs: stamp.captureNs, uncertaintyNs: 1_000_000)
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // Audio → UW writer only, gated on the UW session having begun so we
        // never append audio before startSession (traps "status is 0"),
        // mirroring iPhoneCameraStream:749-761.
        guard isRecording,
              let writer = uwWriter,
              writer.status == .writing,
              uwStartPTS != .zero,
              let audioInput = uwAudioInput,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }
}
#endif
