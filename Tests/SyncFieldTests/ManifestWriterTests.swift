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
}
