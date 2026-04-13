// Sources/SyncField/Streams/iPhoneCameraStream.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public final class iPhoneCameraStream: NSObject, SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true,
        supportsPreciseTimestamps: true,
        providesAudioTrack: true)

    #if canImport(AVFoundation)
    public let captureSession = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "syncfield.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

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
    #endif

    public init(streamId: String) {
        self.streamId = streamId
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
    private func configureSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.Camera",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "back camera not available"]))
        }
        captureSession.addInput(input)

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

        captureSession.commitConfiguration()
    }
    #endif

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        #if canImport(AVFoundation)
        self.clock = clock
        self.frameCount = 0
        self.startPTS = .zero
        self.stampWriter = try writerFactory.makeStreamWriter(streamId: streamId)

        let url = writerFactory.videoURL(streamId: streamId)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        ]
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
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            assetWriterAudioInput = audioInput
        }

        // Start writing BEFORE flipping isRecording. If we flipped first the
        // sample-buffer delegate (running on videoQueue) could race ahead and
        // call `writer.startSession(atSourceTime:)` while the writer is still
        // in status .unknown (0), which aborts with:
        //   "*** -[AVAssetWriter startSessionAtSourceTime:] Cannot call
        //    method when status is 0"
        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown"
            throw StreamError(
                streamId: streamId,
                underlying: NSError(
                    domain: "SyncField.Camera", code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "AVAssetWriter.startWriting() failed: \(reason)"]))
        }

        assetWriter = writer
        assetWriterInput = input
        isRecording = true
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if canImport(AVFoundation)
        isRecording = false
        assetWriterAudioInput?.markAsFinished()
        assetWriterInput?.markAsFinished()
        if let w = assetWriter {
            await withCheckedContinuation { cont in
                w.finishWriting { cont.resume() }
            }
        }
        try await stampWriter?.close()
        let n = frameCount
        stampWriter = nil; assetWriter = nil; assetWriterInput = nil; assetWriterAudioInput = nil
        return StreamStopReport(streamId: streamId, frameCount: n, kind: "video")
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
        #endif
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    // MARK: Frame processor hook

    #if canImport(AVFoundation)
    public func setFrameProcessor(throttleHz: Double = 0,
                                  _ body: @escaping @Sendable (CMSampleBuffer, Int) -> Void) {
        self.throttleHz = throttleHz
        self.frameProcessor = body
    }
    #endif
}

#if canImport(AVFoundation)
extension iPhoneCameraStream: AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Audio path — only forward once the writer is actually in .writing
        // AND the session has begun (startSession has stamped a source time
        // via the first video frame). Audio buffers that arrive before the
        // first video frame are dropped on purpose; otherwise the writer
        // would record audio with no corresponding video track at the same
        // time-origin.
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

        // Frame processor (throttled)
        if let processor = frameProcessor {
            let now = CFAbsoluteTimeGetCurrent()
            let interval = throttleHz > 0 ? 1.0 / throttleHz : 0
            if now - lastProcessorCall >= interval {
                processor(sampleBuffer, frameCount)
                lastProcessorCall = now
            }
        }

        // Recording — only write once the writer is fully in .writing. A
        // brief window exists between `startRecording` flipping `isRecording`
        // and `startWriting()` returning; this guard plus the explicit
        // startWriting-before-isRecording ordering in `startRecording`
        // together eliminate the "status is 0" crash we saw in the wild.
        guard isRecording,
              let writer = assetWriter,
              writer.status == .writing,
              let input = assetWriterInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .zero {
            startPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            // PTS is already in the monotonic host-clock domain on iOS (via the
            // CMClockGetHostTimeClock). Convert seconds -> nanoseconds directly.
            let seconds = CMTimeGetSeconds(pts)
            let monoNs = UInt64(seconds * 1_000_000_000)
            let frame = frameCount
            frameCount += 1
            let w = stampWriter
            Task {
                try? await w?.append(frame: frame,
                                     monotonicNs: monoNs,
                                     uncertaintyNs: 1_000_000)
            }
        }
    }
}
#endif
