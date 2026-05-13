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

/// Optional stream contract for hardware that can cheaply improve stop
/// reliability without changing the stop state machine.
///
/// This hook is best-effort and must not be required for correctness. The
/// orchestrator starts it as soon as stop begins, overlapping it with the stop
/// chirp/tail window, then still calls `stopRecording()` on every stream. Use it
/// for lightweight wake/keepalive nudges, not for blocking command probes.
public protocol SyncFieldRecordingStopPreparationStream: SyncFieldStream {
    func prepareToStopRecording() async
}

/// Optional stream contract for recordings that can be salvaged after the
/// normal stop command fails.
///
/// Host apps use this only after `SessionOrchestrator.stopRecording()` has
/// already moved the session into `.stopping` and returned an error. The user
/// can then manually stop the external device, and the stream writes whatever
/// durable metadata is needed so later ingest/collect can find the file.
public protocol SyncFieldManualStopRecoveryStream: SyncFieldStream {
    func recoverUnconfirmedManualStop(
        stopWallClockMs: UInt64,
        reason: String
    ) async throws -> StreamStopReport
}
