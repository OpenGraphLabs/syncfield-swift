// Tests/SyncFieldTests/SessionOrchestratorAtomicStartTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorAtomicStartTests: XCTestCase {
    func test_failure_in_one_stream_rolls_back_others_and_deletes_files() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let good = MockStream(streamId: "good")
        let bad  = MockStream(streamId: "bad")
        await bad.setFailAt(.start)
        try await s.add(good)
        try await s.add(bad)

        try await s.connect()
        do {
            _ = try await s.startRecording()
            XCTFail("expected startFailed")
        } catch SessionError.startFailed {
            // expected
        }

        // The episode directory that was created must be gone.
        let children = try FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(children.count, 0, "rollback must remove the episode directory")

        // good stream must have been stopped.
        let isRecording = await good.recording
        XCTAssertFalse(isRecording)

        let state = await s.state
        XCTAssertEqual(state, .connected)
    }

    func test_hanging_stream_start_times_out_and_rolls_back() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            startChirp: nil,
            streamStartTimeoutSeconds: 0.05)
        let good = MockStream(streamId: "good")
        let hanging = HangingStartStream(streamId: "hanging")
        try await s.add(good)
        try await s.add(hanging)

        try await s.connect()
        let startedAt = Date()
        do {
            _ = try await s.startRecording()
            XCTFail("expected startFailed")
        } catch SessionError.startFailed(let cause, _) {
            XCTAssertTrue(
                cause.localizedDescription.contains("start timed out"),
                "unexpected cause: \(cause)")
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
        let goodRecording = await good.recording
        let hangingStopCalled = await hanging.stopCalled()
        let state = await s.state
        XCTAssertFalse(goodRecording)
        XCTAssertTrue(hangingStopCalled)
        XCTAssertEqual(state, .connected)
    }
}

private final class HangingStartStream: SyncFieldStream, @unchecked Sendable {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false,
        producesFile: false)

    private let stopFlag = StopFlag()

    init(streamId: String) {
        self.streamId = streamId
    }

    func stopCalled() async -> Bool {
        await stopFlag.value
    }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}

    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }

    func stopRecording() async throws -> StreamStopReport {
        await stopFlag.mark()
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

private actor StopFlag {
    private(set) var value = false

    func mark() {
        value = true
    }
}
