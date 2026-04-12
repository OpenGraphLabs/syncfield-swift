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
}
