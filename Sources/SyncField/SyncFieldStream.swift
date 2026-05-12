// Sources/SyncField/SyncFieldStream.swift
import Foundation

public struct StreamConnectContext: Sendable {
    public let sessionId: String
    public let hostId: String
    public let healthBus: HealthBus

    public init(sessionId: String, hostId: String, healthBus: HealthBus) {
        self.sessionId = sessionId; self.hostId = hostId; self.healthBus = healthBus
    }
}

public struct StreamStopReport: Sendable {
    public let streamId: String
    public let frameCount: Int
    public let kind: String

    public init(streamId: String, frameCount: Int, kind: String) {
        self.streamId = streamId; self.frameCount = frameCount; self.kind = kind
    }
}

public struct StreamIngestReport: Sendable {
    public let streamId: String
    public let filePath: String?        // relative to episode dir; nil if no file produced
    public let frameCount: Int?         // e.g. from timestamps.jsonl after ingest

    public init(streamId: String, filePath: String?, frameCount: Int?) {
        self.streamId = streamId; self.filePath = filePath; self.frameCount = frameCount
    }
}

/// Custom adapter contract. Implemented by `iPhoneCameraStream`,
/// `iPhoneMotionStream`, `TactileStream`, `Insta360CameraStream`, etc.
public protocol SyncFieldStream: Sendable {
    nonisolated var streamId: String { get }
    nonisolated var capabilities: StreamCapabilities { get }

    func prepare() async throws
    func connect(context: StreamConnectContext) async throws
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws
    func stopRecording() async throws -> StreamStopReport
    func ingest(into episodeDirectory: URL,
                progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport
    func disconnect() async throws
}

/// Optional stream contract for hardware that needs a live pre-start check
/// before the user-facing countdown begins.
///
/// `SessionOrchestrator.startRecording(countdown:)` intentionally starts
/// external cameras at countdown begin so the countdown ticks are captured in
/// every audio track. That means a disconnected external camera must be
/// detected before the countdown UI/audio starts, not after. Streams that can
/// cheaply verify or refresh their device connection implement this protocol;
/// all other streams are ignored by `preflightRecording()`.
public protocol SyncFieldRecordingPreflightStream: SyncFieldStream {
    func preflightRecording() async throws
}
