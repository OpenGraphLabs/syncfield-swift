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
