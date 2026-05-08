import Foundation
#if os(iOS)
import CoreMotion
#endif

private func makeRawIMUOperationQueue(name: String) -> OperationQueue {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    queue.name = name
    return queue
}

public final class iPhoneRawAccelStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false, supportsPreciseTimestamps: true)

    private let rateHz: Double
    private var writer: SensorWriter?
    private var writerPump: SensorWriterPump?
    private var opQueue: OperationQueue?
    private var frameCount = 0
    private var healthBus: HealthBus?

    #if os(iOS)
    private let manager = CMMotionManager()
    #endif

    public init(streamId: String = "imu_accel_raw", rateHz: Double = 100) {
        self.streamId = streamId
        self.rateHz = rateHz
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if os(iOS)
        guard manager.isAccelerometerAvailable else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.RawIMU",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "raw accelerometer unavailable"]))
        }
        manager.accelerometerUpdateInterval = 1.0 / rateHz
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        let writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.writer = writer
        self.writerPump = SensorWriterPump(label: "syncfield.raw-accel.writer")
        self.frameCount = 0
        _ = clock

        #if os(iOS)
        manager.accelerometerUpdateInterval = 1.0 / rateHz
        let queue = makeRawIMUOperationQueue(name: "syncfield.raw-accel.motion")
        self.opQueue = queue
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.handle(data)
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if os(iOS)
        manager.stopAccelerometerUpdates()
        opQueue?.waitUntilAllOperationsAreFinished()
        #endif
        writerPump?.flush()
        try await writer?.close()
        let n = frameCount
        writer = nil
        writerPump = nil
        opQueue = nil
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
    private func handle(_ data: CMAccelerometerData) {
        guard let writer = writer, let writerPump = writerPump else { return }
        let ns = UInt64(data.timestamp * 1_000_000_000)
        let frame = frameCount
        frameCount += 1
        let channels: [String: Any] = [
            "accel_x": data.acceleration.x,
            "accel_y": data.acceleration.y,
            "accel_z": data.acceleration.z,
        ]
        writerPump.append(writer: writer,
                          frame: frame,
                          monotonicNs: ns,
                          channels: channels)
    }
    #endif
}

public final class iPhoneRawGyroStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false, supportsPreciseTimestamps: true)

    private let rateHz: Double
    private var writer: SensorWriter?
    private var writerPump: SensorWriterPump?
    private var opQueue: OperationQueue?
    private var frameCount = 0
    private var healthBus: HealthBus?

    #if os(iOS)
    private let manager = CMMotionManager()
    #endif

    public init(streamId: String = "imu_gyro_raw", rateHz: Double = 100) {
        self.streamId = streamId
        self.rateHz = rateHz
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if os(iOS)
        guard manager.isGyroAvailable else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.RawIMU",
                                                  code: -2,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "raw gyro unavailable"]))
        }
        manager.gyroUpdateInterval = 1.0 / rateHz
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        let writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.writer = writer
        self.writerPump = SensorWriterPump(label: "syncfield.raw-gyro.writer")
        self.frameCount = 0
        _ = clock

        #if os(iOS)
        manager.gyroUpdateInterval = 1.0 / rateHz
        let queue = makeRawIMUOperationQueue(name: "syncfield.raw-gyro.motion")
        self.opQueue = queue
        manager.startGyroUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.handle(data)
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if os(iOS)
        manager.stopGyroUpdates()
        opQueue?.waitUntilAllOperationsAreFinished()
        #endif
        writerPump?.flush()
        try await writer?.close()
        let n = frameCount
        writer = nil
        writerPump = nil
        opQueue = nil
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
    private func handle(_ data: CMGyroData) {
        guard let writer = writer, let writerPump = writerPump else { return }
        let ns = UInt64(data.timestamp * 1_000_000_000)
        let frame = frameCount
        frameCount += 1
        let channels: [String: Any] = [
            "gyro_x": data.rotationRate.x,
            "gyro_y": data.rotationRate.y,
            "gyro_z": data.rotationRate.z,
        ]
        writerPump.append(writer: writer,
                          frame: frame,
                          monotonicNs: ns,
                          channels: channels)
    }
    #endif
}

public final class iPhoneRawMagStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false, supportsPreciseTimestamps: true)

    private let rateHz: Double
    private var writer: SensorWriter?
    private var writerPump: SensorWriterPump?
    private var opQueue: OperationQueue?
    private var frameCount = 0
    private var healthBus: HealthBus?

    #if os(iOS)
    private let manager = CMMotionManager()
    #endif

    public init(streamId: String = "imu_mag_raw", rateHz: Double = 100) {
        self.streamId = streamId
        self.rateHz = rateHz
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if os(iOS)
        guard manager.isMagnetometerAvailable else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.RawIMU",
                                                  code: -3,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "raw magnetometer unavailable"]))
        }
        manager.magnetometerUpdateInterval = 1.0 / rateHz
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        let writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.writer = writer
        self.writerPump = SensorWriterPump(label: "syncfield.raw-mag.writer")
        self.frameCount = 0
        _ = clock

        #if os(iOS)
        manager.magnetometerUpdateInterval = 1.0 / rateHz
        let queue = makeRawIMUOperationQueue(name: "syncfield.raw-mag.motion")
        self.opQueue = queue
        manager.startMagnetometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.handle(data)
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if os(iOS)
        manager.stopMagnetometerUpdates()
        opQueue?.waitUntilAllOperationsAreFinished()
        #endif
        writerPump?.flush()
        try await writer?.close()
        let n = frameCount
        writer = nil
        writerPump = nil
        opQueue = nil
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
    private func handle(_ data: CMMagnetometerData) {
        guard let writer = writer, let writerPump = writerPump else { return }
        let ns = UInt64(data.timestamp * 1_000_000_000)
        let frame = frameCount
        frameCount += 1
        let channels: [String: Any] = [
            "mag_x": data.magneticField.x,
            "mag_y": data.magneticField.y,
            "mag_z": data.magneticField.z,
        ]
        writerPump.append(writer: writer,
                          frame: frame,
                          monotonicNs: ns,
                          channels: channels)
    }
    #endif
}
