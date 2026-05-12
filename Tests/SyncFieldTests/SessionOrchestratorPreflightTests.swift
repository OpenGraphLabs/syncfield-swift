import XCTest
@testable import SyncField

private actor PreflightProbeStream: SyncFieldStream, SyncFieldRecordingPreflightStream {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(requiresIngest: false, producesFile: false)

    var didPreflight = false
    var shouldFailPreflight = false

    init(streamId: String) {
        self.streamId = streamId
    }

    func failPreflight() {
        shouldFailPreflight = true
    }

    func preflightRecording() async throws {
        didPreflight = true
        if shouldFailPreflight { throw TestError.boom }
    }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {}
    func stopRecording() async throws -> StreamStopReport {
        StreamStopReport(streamId: streamId, frameCount: 0, kind: "sensor")
    }
    func ingest(into dir: URL, progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
    }
    func disconnect() async throws {}
}

final class SessionOrchestratorPreflightTests: XCTestCase {
    func makeSession() -> (SessionOrchestrator, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionOrchestrator(hostId: "h", outputDirectory: dir), dir)
    }

    func test_preflightRecordingRequiresConnectedState() async throws {
        let (session, _) = makeSession()
        try await session.add(PreflightProbeStream(streamId: "cam_wrist_left"))

        do {
            try await session.preflightRecording()
            XCTFail("expected invalid transition")
        } catch let SessionError.invalidTransition(from, to) {
            XCTAssertEqual(from, .idle)
            XCTAssertEqual(to, .connected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_preflightRecordingCallsOnlyStreamsThatOptIn() async throws {
        let (session, _) = makeSession()
        let probe = PreflightProbeStream(streamId: "cam_wrist_left")
        try await session.add(MockStream(streamId: "cam_ego"))
        try await session.add(probe)
        try await session.connect()

        try await session.preflightRecording()

        let didPreflight = await probe.didPreflight
        let state = await session.state
        XCTAssertTrue(didPreflight)
        XCTAssertEqual(state, .connected)
    }

    func test_preflightRecordingWrapsFailingStreamId() async throws {
        let (session, _) = makeSession()
        let probe = PreflightProbeStream(streamId: "cam_wrist_right")
        await probe.failPreflight()
        try await session.add(probe)
        try await session.connect()

        do {
            try await session.preflightRecording()
            XCTFail("expected stream error")
        } catch let streamError as StreamError {
            XCTAssertEqual(streamError.streamId, "cam_wrist_right")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
