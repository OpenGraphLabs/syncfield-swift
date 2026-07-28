import XCTest
@testable import SyncField

private actor RotatableTestStream: SyncFieldSegmentRotatableStream {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(producesFile: false)
    private var isPrepared = false
    private(set) var prepareCount = 0
    private(set) var commitCount = 0

    init(streamId: String) { self.streamId = streamId }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {}
    func stopRecording() async throws -> StreamStopReport {
        StreamStopReport(streamId: streamId, frameCount: 1, kind: "sensor")
    }
    func ingest(
        into episodeDirectory: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 1)
    }
    func disconnect() async throws {}

    func prepareSegmentRotation(writerFactory: WriterFactory) async throws {
        isPrepared = true
        prepareCount += 1
    }

    func commitSegmentRotation() async throws -> StreamStopReport {
        guard isPrepared else { throw TestError.boom }
        isPrepared = false
        commitCount += 1
        return StreamStopReport(streamId: streamId, frameCount: 42, kind: "sensor")
    }

    func abortSegmentRotation() async { isPrepared = false }
}

final class SessionOrchestratorSegmentRotationTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRotationSealsManifestAndKeepsSessionRecording() async throws {
        let root = try makeRoot()
        let stream = RotatableTestStream(streamId: "imu")
        let session = SessionOrchestrator(
            hostId: "iphone", outputDirectory: root,
            startChirp: nil, stopChirp: nil,
            postStartStabilizationMs: 0, preStopTailMarginMs: 0)
        try await session.add(stream)
        try await session.connect()
        _ = try await session.startRecording()
        let first = await session.episodeDirectory

        let report = try await session.rotateRecordingSegment()
        let stateAfterRotation = await session.state
        let prepareCount = await stream.prepareCount
        let commitCount = await stream.commitCount

        XCTAssertEqual(stateAfterRotation, .recording)
        XCTAssertEqual(report.sealedEpisodeDirectory, first)
        XCTAssertNotEqual(report.nextEpisodeDirectory, first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: first.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: report.nextEpisodeDirectory.appendingPathComponent("sync_point.json").path))
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(commitCount, 1)

        _ = try await session.stopRecording()
        try await session.finishRecording()
    }

    func testUnsupportedStreamFailsBeforeCreatingNextDirectory() async throws {
        let root = try makeRoot()
        let session = SessionOrchestrator(
            hostId: "iphone", outputDirectory: root,
            startChirp: nil, stopChirp: nil,
            postStartStabilizationMs: 0, preStopTailMarginMs: 0)
        try await session.add(MockStream(streamId: "external-camera", kind: "video"))
        try await session.connect()
        _ = try await session.startRecording()
        let before = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

        do {
            _ = try await session.rotateRecordingSegment()
            XCTFail("expected unsupported stream rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsupported"))
        }

        let after = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let stateAfterRejection = await session.state
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(stateAfterRejection, .recording)
        _ = try await session.stopRecording()
        try await session.finishRecording()
    }
}
