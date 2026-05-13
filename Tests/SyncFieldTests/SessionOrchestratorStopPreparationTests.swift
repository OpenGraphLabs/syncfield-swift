import XCTest
@testable import SyncField

private actor StopPreparationProbeStream: SyncFieldStream, SyncFieldRecordingStopPreparationStream {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(requiresIngest: false, producesFile: false)

    var didPrepareToStop = false
    var didStop = false

    init(streamId: String) {
        self.streamId = streamId
    }

    func prepareToStopRecording() async {
        didPrepareToStop = true
    }

    func preparedToStop() -> Bool {
        didPrepareToStop
    }

    func stopped() -> Bool {
        didStop
    }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {}

    func stopRecording() async throws -> StreamStopReport {
        didStop = true
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "sensor")
    }

    func ingest(
        into dir: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
    }

    func disconnect() async throws {}
}

final class SessionOrchestratorStopPreparationTests: XCTestCase {
    func test_stopRecordingRunsBestEffortPreparationBeforeStopping() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            startChirp: nil,
            stopChirp: nil)
        let stream = StopPreparationProbeStream(streamId: "cam_wrist_left")
        try await session.add(stream)
        try await session.connect()
        _ = try await session.startRecording()

        _ = try await session.stopRecording()

        let didPrepareToStop = await stream.preparedToStop()
        let didStop = await stream.stopped()
        XCTAssertTrue(didPrepareToStop)
        XCTAssertTrue(didStop)
    }
}
