// Sources/SyncField/Streams/Tactile/WristImuStream.swift
import Foundation

/// A passive sensor stream for the OGLO glove's wrist-mounted IMU.
///
/// The IMU is co-sampled with the tactile taxels inside one BLE packet, so it
/// has no BLE connection of its own — the owning `TactileStream` parses the
/// packet and pushes each IMU sample here via `append(...)`. Modelling it as a
/// first-class registered stream (rather than extra columns inside the tactile
/// file) keeps modalities separate: it gets its own `wrist_imu_<side>.jsonl`,
/// its own manifest entry, and its own timeline alignment downstream — while
/// sharing the exact same per-sample timestamps as the tactile stream, so the
/// two stay perfectly aligned.
public final class WristImuStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false,
        supportsPreciseTimestamps: true, providesAudioTrack: false)

    private var writer: SensorWriter?
    private var frameCount = 0

    public init(streamId: String) {
        self.streamId = streamId
    }

    public func prepare() async throws {}

    /// No BLE of its own — the owning TactileStream feeds it.
    public func connect(context: StreamConnectContext) async throws {}

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
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

    public func disconnect() async throws {}

    /// Append one IMU sample. Called by the owning TactileStream on the BLE
    /// queue with the SAME timestamps it uses for the matching tactile row, so
    /// the two files stay aligned. No-op until `startRecording` creates a writer
    /// (preview-phase samples are dropped, matching the tactile stream).
    func append(captureNs: UInt64, deviceTimestampNs: UInt64, channels: [String: Int]) {
        guard let writer = writer else { return }
        let frame = frameCount
        frameCount += 1
        let channelsAny: [String: Any] = channels.mapValues { $0 as Any }
        Task {
            try? await writer.append(frame: frame, monotonicNs: captureNs,
                                     channels: channelsAny,
                                     deviceTimestampNs: deviceTimestampNs)
        }
    }
}
