// Sources/SyncField/Streams/Tactile/TactileStream.swift
import Foundation

/// Live sample emitted by `TactileStream.setSampleHandler` — lets host apps
/// subscribe to real-time sensor values for UI preview, gesture recognition,
/// or custom triggers without touching the on-disk JSONL.
///
/// The handler fires on the BLE delivery queue, not the main queue; dispatch
/// to the main thread yourself if the handler updates UI.
public struct TactileSampleEvent: Sendable {
    public let streamId: String
    public let side: TactileSide
    public let frame: Int
    /// Host monotonic nanoseconds (same domain as `SessionClock.nowMonotonicNs()`).
    public let monotonicNs: UInt64
    /// Firmware hardware clock in nanoseconds.
    public let deviceTimestampNs: UInt64
    /// Channel label → raw 12-bit FSR value (0–4095).
    /// Labels come from the firmware manifest (`thumb`, `index`, `middle`, `ring`, `pinky`).
    public let channels: [String: Int]
}

public final class TactileStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false,
        supportsPreciseTimestamps: true, providesAudioTrack: false)

    /// Which glove side this stream is configured for.
    public let side: TactileSide

    private let client = TactileBLEClient()
    private var writer: SensorWriter?
    private var clock: SessionClock?
    private var healthBus: HealthBus?
    private var manifest: DeviceManifest?
    private var frameCount = 0
    private var isSubscribed = false

    private let handlerLock = NSLock()
    private var _sampleHandler: (@Sendable (TactileSampleEvent) -> Void)?

    public init(streamId: String, side: TactileSide) {
        self.streamId = streamId
        self.side = side
    }

    /// Attach (or detach with `nil`) a live sample handler. Safe to call at any
    /// point in the session — connect-time, recording-time, or after stop.
    /// Passing `nil` removes any previously installed handler.
    public func setSampleHandler(_ handler: (@Sendable (TactileSampleEvent) -> Void)?) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        _sampleHandler = handler
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        let ref = try await client.scan()
        let m = try await client.connectAndPrepare(ref, expectedSide: side)
        self.manifest = m

        // Subscribe immediately so the sample handler receives preview data
        // before startRecording begins writing files.
        try client.subscribe { [weak self] data, arrivalNs in
            self?.handlePacket(data, arrivalNs: arrivalNs)
        }
        isSubscribed = true

        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        self.clock = clock
        self.writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.frameCount = 0
    }

    public func stopRecording() async throws -> StreamStopReport {
        let final = frameCount
        try await writer?.close()
        writer = nil
        return StreamStopReport(streamId: streamId, frameCount: final, kind: "sensor")
    }

    public func ingest(into dir: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).jsonl",
                           frameCount: frameCount)
    }

    public func disconnect() async throws {
        isSubscribed = false
        setSampleHandler(nil)
        client.disconnect()
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    private func handlePacket(_ data: Data, arrivalNs: UInt64) {
        guard isSubscribed, let manifest = manifest else { return }
        guard let packet = try? TactilePacketParser.parse(data) else { return }

        let intervalUs = UInt64(TactileConstants.sampleIntervalUs)

        handlerLock.lock()
        let handler = _sampleHandler
        handlerLock.unlock()

        for (i, channels) in packet.samples.enumerated() {
            let frame = frameCount
            frameCount += 1

            let captureNs = arrivalNs &+ UInt64(i) &* (intervalUs &* 1_000)
            let deviceTsNs = (UInt64(packet.batchTimestampUs) &+ UInt64(i) &* intervalUs) &* 1_000

            var channelsOut: [String: Int] = [:]
            for (cid, raw) in channels.enumerated() {
                let label = manifest.locationForChannel(cid) ?? "ch\(cid)"
                channelsOut[label] = Int(raw)
            }

            // Always fire the sample handler so UI/gesture consumers can observe
            // even before startRecording is called (e.g. during pairing preview).
            if let handler = handler {
                handler(TactileSampleEvent(
                    streamId: streamId,
                    side: side,
                    frame: frame,
                    monotonicNs: captureNs,
                    deviceTimestampNs: deviceTsNs,
                    channels: channelsOut))
            }

            // Only persist to JSONL while recording (writer is non-nil only between
            // startRecording and stopRecording).
            if let writer = writer {
                let channelsAny: [String: Any] = channelsOut.mapValues { $0 as Any }
                Task {
                    try? await writer.append(frame: frame, monotonicNs: captureNs,
                                             channels: channelsAny,
                                             deviceTimestampNs: deviceTsNs)
                }
            }
        }
    }
}
