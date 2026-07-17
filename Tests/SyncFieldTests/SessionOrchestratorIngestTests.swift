// Tests/SyncFieldTests/SessionOrchestratorIngestTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorIngestTests: XCTestCase {
    func test_stop_manifest_uses_video_file_path_without_ingest() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(MockStream(streamId: "cam_ego", kind: "video"))
        try await s.add(MockStream(streamId: "imu", kind: "sensor"))

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()

        let episode = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).first!
        let manifestURL = episode.appendingPathComponent("manifest.json")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as! [String: Any]
        let streams = manifest["streams"] as! [[String: Any]]

        let cam = streams.first { $0["stream_id"] as? String == "cam_ego" }
        let imu = streams.first { $0["stream_id"] as? String == "imu" }
        XCTAssertEqual(cam?["file_path"] as? String, "cam_ego.mp4")
        XCTAssertEqual(imu?["file_path"] as? String, "imu.jsonl")
    }

    func test_partial_ingest_failure_is_reported_not_raised() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let ok  = MockStream(streamId: "ok")
        let bad = MockStream(streamId: "bad")
        await bad.setFailAt(.ingest)
        try await s.add(ok)
        try await s.add(bad)

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        let report = try await s.ingest { _ in }

        if case .success = report.streamResults["ok"]! { /* ok */ } else { XCTFail() }
        if case .failure = report.streamResults["bad"]! { /* ok */ } else { XCTFail() }
    }

    func test_manifest_includes_all_entries_from_a_multi_entry_stream() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let stereo = MultiEntryFakeStream(
            streamId: "cam_ego_stereo",
            entries: [
                .init(streamId: "cam_ego", filePath: "cam_ego.mp4",
                      frameCount: 0, kind: "video", capabilities: StreamCapabilities()),
                .init(streamId: "cam_ego_wide", filePath: "cam_ego_wide.mp4",
                      frameCount: 0, kind: "video", capabilities: StreamCapabilities(),
                      syncGroupId: "cam_ego"),
            ])
        try await s.add(stereo)
        try await s.add(MockStream(streamId: "imu", kind: "sensor"))

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()

        let episode = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).first!
        let manifestURL = episode.appendingPathComponent("manifest.json")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as! [String: Any]
        let streams = manifest["streams"] as! [[String: Any]]

        XCTAssertEqual(streams.count, 3)
        XCTAssertTrue(streams.contains { $0["stream_id"] as? String == "cam_ego" })
        let wide = streams.first { $0["stream_id"] as? String == "cam_ego_wide" }
        XCTAssertEqual(wide?["sync_group_id"] as? String, "cam_ego")
        XCTAssertTrue(streams.contains { $0["stream_id"] as? String == "imu" })
    }
}
