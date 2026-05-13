import XCTest
@testable import SyncField

private actor ManualStopRecoveryProbeStream: SyncFieldManualStopRecoveryStream {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(
        requiresIngest: true,
        producesFile: true,
        supportsPreciseTimestamps: true,
        providesAudioTrack: true)

    private(set) var stopCallCount = 0
    private(set) var recoveryCallCount = 0
    private(set) var recoveredStopWallClockMs: UInt64?
    private(set) var recoveredReason: String?

    init(streamId: String) {
        self.streamId = streamId
    }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {}

    func stopRecording() async throws -> StreamStopReport {
        stopCallCount += 1
        throw TestError.boom
    }

    func recoverUnconfirmedManualStop(
        stopWallClockMs: UInt64,
        reason: String
    ) async throws -> StreamStopReport {
        recoveryCallCount += 1
        recoveredStopWallClockMs = stopWallClockMs
        recoveredReason = reason
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
    }

    func ingest(into episodeDirectory: URL, progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: "\(streamId).mp4", frameCount: nil)
    }

    func disconnect() async throws {}
}

final class SessionOrchestratorManualStopRecoveryTests: XCTestCase {
    private func makeSession() -> (SessionOrchestrator, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-manual-stop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (
            SessionOrchestrator(
                hostId: "h",
                outputDirectory: dir,
                stopChirp: nil,
                preStopTailMarginMs: 0),
            dir
        )
    }

    func test_recoverUnconfirmedStops_fillsMissingRecoverableReports() async throws {
        let (session, _) = makeSession()
        let native = MockStream(streamId: "cam_ego", kind: "video")
        let wrist = ManualStopRecoveryProbeStream(streamId: "cam_wrist_left")
        try await session.add(native)
        try await session.add(wrist)

        try await session.connect()
        _ = try await session.startRecording()

        do {
            _ = try await session.stopRecording()
            XCTFail("expected stop to fail before manual recovery")
        } catch {
            let state = await session.state
            XCTAssertEqual(state, .stopping)
        }

        let manualStopWallClockMs: UInt64 = 1_778_688_360_000
        let report = try await session.recoverUnconfirmedStops(
            manualStopWallClockMs: manualStopWallClockMs,
            reason: "user_confirmed_manual_stop")

        XCTAssertEqual(report.streamReports.map(\.streamId), ["cam_ego", "cam_wrist_left"])
        let stopCallCount = await wrist.stopCallCount
        let recoveryCallCount = await wrist.recoveryCallCount
        let recoveredStopWallClockMs = await wrist.recoveredStopWallClockMs
        let recoveredReason = await wrist.recoveredReason
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertEqual(recoveryCallCount, 1)
        XCTAssertEqual(recoveredStopWallClockMs, manualStopWallClockMs)
        XCTAssertEqual(recoveredReason, "user_confirmed_manual_stop")

        try await session.finishRecording()
        let state = await session.state
        XCTAssertEqual(state, .connected)
    }

    func test_recoverUnconfirmedStops_rejectsNonRecoverableFailedStreams() async throws {
        let (session, _) = makeSession()
        let stream = MockStream(streamId: "cam_ego")
        await stream.setFailAt(.stop)
        try await session.add(stream)

        try await session.connect()
        _ = try await session.startRecording()

        do {
            _ = try await session.stopRecording()
            XCTFail("expected stop to fail")
        } catch {
            let state = await session.state
            XCTAssertEqual(state, .stopping)
        }

        do {
            _ = try await session.recoverUnconfirmedStops()
            XCTFail("expected manual recovery to reject unsupported stream")
        } catch let error as StreamError {
            XCTAssertEqual(error.streamId, "cam_ego")
            guard case SessionError.manualStopRecoveryUnsupported("cam_ego") = error.underlying else {
                XCTFail("unexpected underlying error \(error.underlying)")
                return
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
