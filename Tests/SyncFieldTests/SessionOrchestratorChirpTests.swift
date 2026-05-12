// Tests/SyncFieldTests/SessionOrchestratorChirpTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorChirpTests: XCTestCase {
    final class SpyChirpPlayer: ChirpPlayer, @unchecked Sendable {
        var played: [ChirpSpec] = []
        var isSilent: Bool { false }
        func play(_ spec: ChirpSpec) async -> ChirpEmission {
            played.append(spec)
            return ChirpEmission(softwareNs: 42, hardwareNs: nil, source: .softwareFallback)
        }
    }

    func test_start_and_stop_chirps_are_emitted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = SpyChirpPlayer()
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: spy,
                                    postStartStabilizationMs: 0,
                                    preStopTailMarginMs: 0)
        try await s.add(MockStream(streamId: "a"))

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        XCTAssertEqual(spy.played.count, 2)
        XCTAssertEqual(spy.played[0], .defaultStart)
        XCTAssertEqual(spy.played[1], .defaultStop)
    }

    func test_chirp_timestamps_land_in_sync_point_json() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: SpyChirpPlayer(),
                                    postStartStabilizationMs: 0,
                                    preStopTailMarginMs: 0)
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }

        let episodeDir = await s.episodeDirectory
        let spURL = episodeDir.appendingPathComponent("sync_point.json")
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: spURL)) as! [String: Any]
        XCTAssertEqual(dict["chirp_start_ns"] as? UInt64, 42)
        XCTAssertEqual(dict["chirp_stop_ns"] as? UInt64, 42)
        XCTAssertEqual(dict["chirp_start_source"] as? String, "software_fallback")
        XCTAssertNotNil(dict["chirp_spec"])
    }

    func test_chirps_can_be_disabled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = SpyChirpPlayer()
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: spy,
                                    startChirp: nil,
                                    stopChirp: nil)
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }

        XCTAssertTrue(spy.played.isEmpty)
    }

    /// Production guard: ``stopRecording()`` must hold the recording open
    /// past the stop chirp by at least ``chirp.durationMs +
    /// preStopTailMarginMs``. Without that hold, hosts with stop latency
    /// (Insta360 wrist cams in particular) lose the chirp tail and the
    /// downstream audio sync's ±400 ms cross-correlation window collapses
    /// — exactly the failure mode the new default 800 ms tail is sized to
    /// prevent. This test pins the contract so a future refactor can't
    /// silently shorten it.
    func test_stopRecording_waits_for_chirp_plus_tail_before_stopping_streams() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Use a shortened chirp so the test runs quickly while still
        // exercising the wait math (durationMs + preStopTailMarginMs).
        let shortChirp = ChirpSpec(fromHz: 400, toHz: 800,
                                    durationMs: 100, amplitude: 0.5,
                                    envelopeMs: 5)
        let tailMs: Double = 250

        // MockStream timestamps stopRecording entry — that is the moment
        // the per-stream BLE / writer-close fires, i.e. the latest moment
        // any host stops capturing the chirp tail.
        final class StopTimedMockStream: SyncFieldStream, @unchecked Sendable {
            let streamId: String
            var stopEnteredNs: UInt64?
            init(streamId: String) { self.streamId = streamId }
            var capabilities: StreamCapabilities {
                StreamCapabilities(requiresIngest: false,
                                   producesFile: false,
                                   supportsPreciseTimestamps: false,
                                   providesAudioTrack: false)
            }
            func prepare() async throws {}
            func connect(context: StreamConnectContext) async throws {}
            func startRecording(clock: SessionClock,
                                writerFactory: WriterFactory) async throws {}
            func stopRecording() async throws -> StreamStopReport {
                stopEnteredNs = DispatchTime.now().uptimeNanoseconds
                return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
            }
            func ingest(into episodeDirectory: URL,
                        progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
                StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
            }
            func disconnect() async throws {}
        }

        let stream = StopTimedMockStream(streamId: "a")
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: SpyChirpPlayer(),
                                    startChirp: nil,
                                    stopChirp: shortChirp,
                                    postStartStabilizationMs: 0,
                                    preStopTailMarginMs: tailMs)
        try await s.add(stream)
        try await s.connect()
        _ = try await s.startRecording()
        let stopCalledNs = DispatchTime.now().uptimeNanoseconds
        _ = try await s.stopRecording()

        guard let entered = stream.stopEnteredNs else {
            return XCTFail("stream.stopRecording was never called")
        }
        let waitedMs = Double(entered - stopCalledNs) / 1_000_000.0
        let expectedMs = shortChirp.durationMs + tailMs
        // Allow some scheduling slack but require we did NOT short-circuit.
        XCTAssertGreaterThanOrEqual(
            waitedMs, expectedMs - 5,
            "stopRecording must hold recording for ≥ chirp(\(shortChirp.durationMs))+tail(\(tailMs)) ms before tearing down streams; got \(waitedMs) ms"
        )
    }

    /// Default ``preStopTailMarginMs`` must stay generous enough to cover
    /// the precise-xcorr ±400 ms window plus typical Insta360 stop slack.
    /// This is a numeric pin so anyone shrinking the default has to update
    /// the test deliberately and look at the comment explaining why.
    func test_preStopTailMarginMs_default_is_at_least_800() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // We can't read the private field directly, so we exercise it: a
        // session that uses the default stop-tail and a 50 ms chirp must
        // wait ≥ 850 ms in stopRecording() before tearing down streams.
        final class StopTimedMockStream: SyncFieldStream, @unchecked Sendable {
            let streamId: String
            var stopEnteredNs: UInt64?
            init(streamId: String) { self.streamId = streamId }
            var capabilities: StreamCapabilities {
                StreamCapabilities(requiresIngest: false,
                                   producesFile: false,
                                   supportsPreciseTimestamps: false,
                                   providesAudioTrack: false)
            }
            func prepare() async throws {}
            func connect(context: StreamConnectContext) async throws {}
            func startRecording(clock: SessionClock,
                                writerFactory: WriterFactory) async throws {}
            func stopRecording() async throws -> StreamStopReport {
                stopEnteredNs = DispatchTime.now().uptimeNanoseconds
                return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
            }
            func ingest(into episodeDirectory: URL,
                        progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
                StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
            }
            func disconnect() async throws {}
        }

        let shortChirp = ChirpSpec(fromHz: 400, toHz: 800,
                                    durationMs: 50, amplitude: 0.5,
                                    envelopeMs: 5)
        let stream = StopTimedMockStream(streamId: "a")
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: SpyChirpPlayer(),
                                    startChirp: nil,
                                    stopChirp: shortChirp,
                                    postStartStabilizationMs: 0)
        try await s.add(stream)
        try await s.connect()
        _ = try await s.startRecording()
        let stopCalledNs = DispatchTime.now().uptimeNanoseconds
        _ = try await s.stopRecording()

        guard let entered = stream.stopEnteredNs else {
            return XCTFail("stream.stopRecording was never called")
        }
        let waitedMs = Double(entered - stopCalledNs) / 1_000_000.0
        XCTAssertGreaterThanOrEqual(
            waitedMs, 50 + 800 - 5,
            "Default preStopTailMarginMs must remain ≥ 800 ms (currently \(waitedMs - 50) ms tail). The 800 ms baseline is required to (a) leave the audio aligner's ±400 ms precise-xcorr window with usable post-chirp silence on every host and (b) absorb the Insta360 wrist cameras' ~300–400 ms stop-side mp4 truncation. Lowering this default re-introduces the ego_wrist sync failure observed in production through 2026-05-12."
        )
    }
}
