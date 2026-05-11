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

    func test_finishRecording_transitions_stopping_to_connected() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        var state = await s.state; XCTAssertEqual(state, .stopping)

        try await s.finishRecording()
        state = await s.state; XCTAssertEqual(state, .connected)

        try await s.disconnect()
        state = await s.state; XCTAssertEqual(state, .idle)
    }

    func test_finishRecording_does_not_call_stream_ingest() async throws {
        let (s, _) = makeSession()
        let stream = MockStream(streamId: "a")
        try await s.add(stream)

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        try await s.finishRecording()

        let ingested = await stream.ingested
        XCTAssertFalse(ingested, "finishRecording must NOT trigger per-stream ingest")
    }

    func test_finishRecording_then_disconnect_is_clean() async throws {
        // The whole point of finishRecording: deferred-collect flow must
        // reach .idle without a throw. Previously the only path out of
        // .stopping was ingest(), forcing host apps to swallow throws.
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        try await s.finishRecording()
        try await s.disconnect()  // must not throw

        let state = await s.state
        XCTAssertEqual(state, .idle)
    }

    func test_finishRecording_from_idle_throws() async {
        let (s, _) = makeSession()
        do {
            try await s.finishRecording()
            XCTFail("expected throw")
        } catch let SessionError.invalidTransition(from, to) {
            XCTAssertEqual(from, .idle)
            XCTAssertEqual(to, .connected)
        } catch { XCTFail("unexpected \(error)") }
    }

    func test_ingest_and_finishRecording_are_mutually_exclusive() async throws {
        // Once a path out of .stopping is chosen the other is no longer
        // available — the state has already moved on.
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }

        do {
            try await s.finishRecording()
            XCTFail("expected throw")
        } catch SessionError.invalidTransition { /* ok */ }
        catch { XCTFail("unexpected \(error)") }
    }

    // MARK: remove(streamId:)

    func test_streamIds_returns_registered_ids_in_order() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.add(MockStream(streamId: "b"))
        let ids = await s.streamIds()
        XCTAssertEqual(ids, ["a", "b"])
    }

    func test_remove_drops_registered_stream() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.add(MockStream(streamId: "b"))

        let removed = try await s.remove(streamId: "a")
        XCTAssertTrue(removed)
        let ids = await s.streamIds()
        XCTAssertEqual(ids, ["b"])
    }

    func test_remove_is_idempotent_when_streamId_not_registered() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))

        let removed = try await s.remove(streamId: "nonexistent")
        XCTAssertFalse(removed)
        let ids = await s.streamIds()
        XCTAssertEqual(ids, ["a"], "remove must not mutate state when streamId is unknown")
    }

    func test_remove_allowed_in_connected_state() async throws {
        // The Remap case: host has connected the session, then needs to
        // deregister a wrist Insta360 to swap it for a different camera
        // under the same role.
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "cam_wrist_right"))
        try await s.add(MockStream(streamId: "anchor"))
        try await s.connect()

        let removed = try await s.remove(streamId: "cam_wrist_right")
        XCTAssertTrue(removed)
        let ids = await s.streamIds()
        XCTAssertEqual(ids, ["anchor"])
        let state = await s.state
        XCTAssertEqual(state, .connected, "remove must not transition state")
    }

    func test_add_after_remove_with_same_streamId_succeeds() async throws {
        // Regression test for the production bug: host paired Camera A as
        // cam_wrist_right, later unpaired it and tried to pair Camera B
        // under the same role. Without remove(), the second add() threw
        // duplicateStreamId because the orchestrator still tracked the
        // original cam_wrist_right entry.
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "cam_wrist_right"))
        try await s.connect()

        // Simulate user pressing Remap, then re-pairing a different camera.
        _ = try await s.remove(streamId: "cam_wrist_right")
        try await s.add(MockStream(streamId: "cam_wrist_right"))

        let ids = await s.streamIds()
        XCTAssertEqual(ids, ["cam_wrist_right"])
    }

    func test_remove_during_recording_throws_invalid_transition() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()
        _ = try await s.startRecording()

        do {
            _ = try await s.remove(streamId: "a")
            XCTFail("expected throw")
        } catch SessionError.invalidTransition { /* ok */ }
        catch { XCTFail("unexpected \(error)") }

        let ids = await s.streamIds()
        XCTAssertEqual(ids, ["a"], "rejected remove must not mutate state")
    }
}
