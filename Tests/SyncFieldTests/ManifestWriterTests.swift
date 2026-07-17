// Tests/SyncFieldTests/ManifestWriterTests.swift
import XCTest
@testable import SyncField

final class ManifestWriterTests: XCTestCase {
    func test_writes_expected_top_level_keys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = Manifest(
            sdkVersion: "0.2.0", hostId: "h", role: "single",
            streams: [
                .init(streamId: "cam_ego", filePath: "cam_ego.mp4",
                      frameCount: 120, kind: "video",
                      capabilities: StreamCapabilities()),
            ])
        let url = dir.appendingPathComponent("manifest.json")
        try ManifestWriter.write(manifest, to: url)

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(dict["sdk_version"] as? String, "0.2.0")
        XCTAssertEqual(dict["host_id"] as? String, "h")
        XCTAssertEqual(dict["role"] as? String, "single")
        XCTAssertNotNil(dict["streams"])
    }

    func test_entry_with_sync_group_id_serializes_the_key() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = Manifest(
            sdkVersion: "0.11.0", hostId: "h", role: "single",
            streams: [
                .init(streamId: "cam_ego_wide", filePath: "cam_ego_wide.mp4",
                      frameCount: 90, kind: "video",
                      capabilities: StreamCapabilities(),
                      syncGroupId: "cam_ego"),
            ])
        let url = dir.appendingPathComponent("manifest.json")
        try ManifestWriter.write(manifest, to: url)

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let streams = dict["streams"] as! [[String: Any]]
        XCTAssertEqual(streams.first?["sync_group_id"] as? String, "cam_ego")
    }

    func test_entry_without_sync_group_id_omits_the_key() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = Manifest(
            sdkVersion: "0.11.0", hostId: "h", role: "single",
            streams: [
                .init(streamId: "cam_ego", filePath: "cam_ego.mp4",
                      frameCount: 120, kind: "video",
                      capabilities: StreamCapabilities()),
            ])
        let url = dir.appendingPathComponent("manifest.json")
        try ManifestWriter.write(manifest, to: url)

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let streams = dict["streams"] as! [[String: Any]]
        XCTAssertFalse(streams.first!.keys.contains("sync_group_id"))
    }

    func test_stream_reporting_two_manifest_entries_produces_both_in_order() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = MultiEntryFakeStream(
            streamId: "cam_ego_stereo",
            entries: [
                .init(streamId: "cam_ego", filePath: "cam_ego.mp4",
                      frameCount: 100, kind: "video",
                      capabilities: StreamCapabilities()),
                .init(streamId: "cam_ego_wide", filePath: "cam_ego_wide.mp4",
                      frameCount: 100, kind: "video",
                      capabilities: StreamCapabilities(),
                      syncGroupId: "cam_ego"),
            ])
        let streams: [any SyncFieldStream] = [fake]
        // This mirrors what SessionOrchestrator.writeManifest does: flat-map
        // manifestEntries across every registered stream instead of building
        // one entry per stream.
        let entries = streams.flatMap { $0.manifestEntries(report: nil) }

        let manifest = Manifest(
            sdkVersion: "0.11.0", hostId: "h", role: "single", streams: entries)
        let url = dir.appendingPathComponent("manifest.json")
        try ManifestWriter.write(manifest, to: url)

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let streamsJSON = dict["streams"] as! [[String: Any]]
        XCTAssertEqual(streamsJSON.count, 2)
        XCTAssertEqual(streamsJSON[0]["stream_id"] as? String, "cam_ego")
        XCTAssertEqual(streamsJSON[1]["stream_id"] as? String, "cam_ego_wide")
        XCTAssertEqual(streamsJSON[1]["sync_group_id"] as? String, "cam_ego")
    }
}
