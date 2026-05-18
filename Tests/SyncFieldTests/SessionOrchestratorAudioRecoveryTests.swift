// Tests/SyncFieldTests/SessionOrchestratorAudioRecoveryTests.swift
import XCTest
@testable import SyncField

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Test double that conforms to both `SyncFieldStream` (so the
/// orchestrator accepts it) and `AudioReattachableStream` (so the recovery
/// path targets it). Counts reattach invocations for the assertion.
final class MockAudioStream: NSObject, SyncFieldStream, AudioReattachableStream, @unchecked Sendable {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false,
        producesFile: false,
        supportsPreciseTimestamps: true,
        providesAudioTrack: true)

    private let lock = NSLock()
    private var _reattachCount = 0
    var reattachCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _reattachCount
    }

    init(streamId: String) { self.streamId = streamId }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {}
    func stopRecording() async throws -> StreamStopReport {
        StreamStopReport(streamId: streamId, frameCount: 0, kind: "audio")
    }
    func ingest(into dir: URL,
                progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
    }
    func disconnect() async throws {}

    func reattachAudioInput() async throws {
        lock.lock(); _reattachCount += 1; lock.unlock()
    }
}

final class SessionOrchestratorAudioRecoveryTests: XCTestCase {

    /// GREEN: an `.ended` interruption posted while the orchestrator is in
    /// `.connected` state (post-connect, pre-recording) triggers reattach
    /// only if the orchestrator is actively recording or stopping. We guard
    /// against spurious reattaches during the wrong lifecycle phase.
    func test_interruption_during_connected_state_does_not_reattach() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orch = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            audioSessionPolicy: .managedBySDK)
        let mock = MockAudioStream(streamId: "iphone")
        try await orch.add(mock)
        try await orch.connect()

        // Connected but NOT recording — interruption.ended should be a no-op
        // for reattach.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.ended.rawValue])

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(mock.reattachCount, 0,
                       "reattach must not fire outside recording/stopping state")

        try? await orch.disconnect()
    }

    /// GREEN: disconnect() removes the interruption observer. After
    /// disconnect, a posted `.ended` notification must not reach the
    /// recovery callback (which would otherwise touch a torn-down state).
    func test_disconnect_unsubscribes_interruption_handler() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orch = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            audioSessionPolicy: .managedBySDK)
        let mock = MockAudioStream(streamId: "iphone")
        try await orch.add(mock)
        try await orch.connect()
        try await orch.disconnect()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.ended.rawValue])

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(mock.reattachCount, 0,
                       "no reattach after disconnect")
    }

    /// manualByHost policy must NOT install the interruption observer at
    /// all — the host owns audio lifecycle in that mode.
    func test_manualByHost_policy_skips_interruption_observer() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orch = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            audioSessionPolicy: .manualByHost)
        let mock = MockAudioStream(streamId: "iphone")
        try await orch.add(mock)
        try await orch.connect()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey:
                       AVAudioSession.InterruptionType.ended.rawValue])

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(mock.reattachCount, 0,
                       "manualByHost must not auto-reattach")

        try? await orch.disconnect()
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir
    }
}

#endif
