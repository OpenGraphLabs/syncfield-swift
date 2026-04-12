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
}
