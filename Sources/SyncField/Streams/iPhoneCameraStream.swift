// Sources/SyncField/Streams/iPhoneCameraStream.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public final class iPhoneCameraStream: NSObject, SyncField.Stream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true, supportsPreciseTimestamps: true)

    #if canImport(AVFoundation)
    public let captureSession = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "syncfield.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
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

        assetWriter = writer
        assetWriterInput = input
        isRecording = true
        writer.startWriting()
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if canImport(AVFoundation)
        isRecording = false
        assetWriterInput?.markAsFinished()
        if let w = assetWriter {
            await withCheckedContinuation { cont in
                w.finishWriting { cont.resume() }
            }
        }
        try await stampWriter?.close()
        let n = frameCount
        stampWriter = nil; assetWriter = nil; assetWriterInput = nil
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
extension iPhoneCameraStream: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Frame processor (throttled)
        if let processor = frameProcessor {
            let now = CFAbsoluteTimeGetCurrent()
            let interval = throttleHz > 0 ? 1.0 / throttleHz : 0
            if now - lastProcessorCall >= interval {
                processor(sampleBuffer, frameCount)
                lastProcessorCall = now
            }
        }

        // Recording
        guard isRecording,
              let writer = assetWriter,
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
