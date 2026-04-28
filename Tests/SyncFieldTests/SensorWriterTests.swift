// Tests/SyncFieldTests/SensorWriterTests.swift
import XCTest
@testable import SyncField

final class SensorWriterTests: XCTestCase {
    func test_writes_channels_as_nested_json_object() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("imu.jsonl")
        let w = try await SensorWriter(url: url)
        try await w.append(frame: 0, monotonicNs: 123,
                           channels: ["accel_x": 0.1, "accel_y": -9.8])
        try await w.close()

        let line = try String(contentsOf: url).split(separator: "\n").first!
        let obj = try JSONSerialization.jsonObject(with: Data(String(line).utf8)) as! [String: Any]
        XCTAssertEqual(obj["frame_number"] as? Int, 0)
        XCTAssertEqual(obj["capture_ns"] as? UInt64, 123)
        let channels = obj["channels"] as! [String: Any]
        XCTAssertEqual(channels["accel_x"] as? Double, 0.1)
    }
}
