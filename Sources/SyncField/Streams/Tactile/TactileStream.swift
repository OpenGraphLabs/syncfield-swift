// Sources/SyncField/Streams/Tactile/TactileStream.swift
import Foundation

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

    public init(streamId: String, side: TactileSide) {
        self.streamId = streamId
        self.side = side
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        let ref = try await client.scan()
        let m = try await client.connectAndPrepare(ref, expectedSide: side)
        self.manifest = m
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        self.clock = clock
        self.writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.frameCount = 0

        try client.subscribe { [weak self] data, arrivalNs in
            self?.handlePacket(data, arrivalNs: arrivalNs)
        }
        isSubscribed = true
    }

    public func stopRecording() async throws -> StreamStopReport {
        isSubscribed = false
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
        client.disconnect()
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    private func handlePacket(_ data: Data, arrivalNs: UInt64) {
        guard isSubscribed,
              let writer = writer,
              let manifest = manifest else { return }
        guard let packet = try? TactilePacketParser.parse(data) else { return }

        let intervalUs = UInt64(TactileConstants.sampleIntervalUs)
        for (i, channels) in packet.samples.enumerated() {
            let frame = frameCount
            frameCount += 1

            // Host timestamp: back-date from arrival using sample interval within batch
            let captureNs = arrivalNs &+ UInt64(i) &* (intervalUs &* 1_000)

            // Device timestamp: firmware batch μs timestamp + per-sample offset, converted to ns
            let deviceTsNs = (UInt64(packet.batchTimestampUs) &+ UInt64(i) &* intervalUs) &* 1_000

            var channelsOut: [String: Any] = [:]
            for (cid, raw) in channels.enumerated() {
                let label = manifest.locationForChannel(cid) ?? "ch\(cid)"
                channelsOut[label] = Int(raw)
            }

            let w = writer
            Task {
                try? await w.append(frame: frame, monotonicNs: captureNs,
                                    channels: channelsOut,
                                    deviceTimestampNs: deviceTsNs)
            }
        }
    }
}
