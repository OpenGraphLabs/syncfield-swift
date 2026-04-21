// Tests/SyncFieldTests/iPhoneCameraStreamTests.swift
#if os(iOS)
import XCTest
import AVFoundation
@testable import SyncField

final class iPhoneCameraStreamTests: XCTestCase {
    func test_produces_mp4_and_matching_timestamp_line_count() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego")
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let episodeDir = await s.episodeDirectory
        let mp4 = episodeDir.appendingPathComponent("cam_ego.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))

        let stamps = episodeDir.appendingPathComponent("cam_ego.timestamps.jsonl")
        let lines = try String(contentsOf: stamps).split(separator: "\n")
        let camReport = stop.streamReports.first { $0.streamId == "cam_ego" }!
        XCTAssertEqual(lines.count, camReport.frameCount)
    }

    /// Ensures the 720p preset actually lands a 1280×720 track in the output.
    /// Also serves as a smoke test that the new `videoSettings` init plumbs
    /// through to the AVAssetWriter output settings.
    func test_hd720_preset_produces_1280x720_track() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720)
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let episodeDir = await s.episodeDirectory
        let mp4 = episodeDir.appendingPathComponent("cam_ego.mp4")
        let asset = AVURLAsset(url: mp4)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first)
        let size = try await videoTrack.load(.naturalSize)
        // 720p landed as requested (sensor buffers arrive as 1280×720 so the
        // encoder emits the track at that native size).
        XCTAssertEqual(size.width,  1280, accuracy: 0)
        XCTAssertEqual(size.height, 720,  accuracy: 0)
    }
}
#endif
