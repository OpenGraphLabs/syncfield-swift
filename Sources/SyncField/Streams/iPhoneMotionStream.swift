// Sources/SyncField/Streams/iPhoneMotionStream.swift
import Foundation
#if os(iOS)
import CoreMotion
#endif

public final class iPhoneMotionStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false, supportsPreciseTimestamps: true)

    private let rateHz: Double
    private let queue = DispatchQueue(label: "syncfield.motion", qos: .userInitiated)

    private var writer: SensorWriter?
    private var clock: SessionClock?
    private var frameCount = 0
    private var healthBus: HealthBus?

    #if os(iOS)
    private let manager = CMMotionManager()
    #endif

    public init(streamId: String, rateHz: Double = 100) {
        self.streamId = streamId
        self.rateHz = rateHz
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if os(iOS)
        guard manager.isDeviceMotionAvailable else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.Motion",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "device motion unavailable"]))
        }
        manager.deviceMotionUpdateInterval = 1.0 / rateHz
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        self.writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.clock = clock
        self.frameCount = 0

        #if os(iOS)
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: opQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if os(iOS)
        manager.stopDeviceMotionUpdates()
        #endif
        try await writer?.close()
        let n = frameCount
        writer = nil
        return StreamStopReport(streamId: streamId, frameCount: n, kind: "sensor")
    }

    public func ingest(into dir: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).jsonl",
                           frameCount: frameCount)
    }

    public func disconnect() async throws {
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    #if os(iOS)
    private func handle(_ motion: CMDeviceMotion) {
        guard let clock = clock, let writer = writer else { return }
        // CMDeviceMotion.timestamp is seconds since device boot (monotonic).
        // Multiply by 1e9 for ns.
        let ns = UInt64(motion.timestamp * 1_000_000_000)
        _ = clock  // clock currently unused; kept for future conversion hook
        let frame = frameCount
        frameCount += 1

        let channels: [String: Any] = [
            "accel_x": motion.userAcceleration.x,
            "accel_y": motion.userAcceleration.y,
            "accel_z": motion.userAcceleration.z,
            "gyro_x":  motion.rotationRate.x,
            "gyro_y":  motion.rotationRate.y,
            "gyro_z":  motion.rotationRate.z,
            "gravity_x": motion.gravity.x,
            "gravity_y": motion.gravity.y,
            "gravity_z": motion.gravity.z,
        ]
        Task { [writer] in
            try? await writer.append(frame: frame, monotonicNs: ns,
                                     channels: channels,
                                     deviceTimestampNs: nil)
        }
    }
    #endif
}
