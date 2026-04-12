// Tests/SyncFieldTests/SessionOrchestratorStateMachineTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorStateMachineTests: XCTestCase {
    func makeSession() -> (SessionOrchestrator, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionOrchestrator(hostId: "h", outputDirectory: dir), dir)
    }

    func test_initial_state_is_idle() async {
        let (s, _) = makeSession()
        let state = await s.state
        XCTAssertEqual(state, .idle)
    }

    func test_happy_path_transitions() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))

        try await s.connect()
        var state = await s.state; XCTAssertEqual(state, .connected)

        _ = try await s.startRecording()
        state = await s.state; XCTAssertEqual(state, .recording)

        _ = try await s.stopRecording()
        state = await s.state; XCTAssertEqual(state, .stopping)

        _ = try await s.ingest { _ in }
        state = await s.state; XCTAssertEqual(state, .connected)

        try await s.disconnect()
        state = await s.state; XCTAssertEqual(state, .idle)
    }

    func test_start_without_connect_throws_invalid_transition() async {
        let (s, _) = makeSession()
        try? await s.add(MockStream(streamId: "a"))
        do {
            _ = try await s.startRecording()
            XCTFail("expected throw")
        } catch let SessionError.invalidTransition(from, _) {
            XCTAssertEqual(from, .idle)
        } catch { XCTFail("unexpected \(error)") }
    }

    func test_add_duplicate_stream_id_throws() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        do {
            try await s.add(MockStream(streamId: "a"))
            XCTFail("expected throw")
        } catch SessionError.duplicateStreamId { /* ok */ }
        catch { XCTFail("unexpected \(error)") }
    }
}
