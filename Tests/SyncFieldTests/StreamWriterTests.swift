// Tests/SyncFieldTests/StreamWriterTests.swift
import XCTest
@testable import SyncField

final class StreamWriterTests: XCTestCase {
    func test_writes_one_json_line_per_frame_and_flushes_on_close() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("cam.timestamps.jsonl")
        let writer = try await StreamWriter(url: url)
        try await writer.append(frame: 0, monotonicNs: 1_000, uncertaintyNs: 5_000_000)
        try await writer.append(frame: 1, monotonicNs: 2_000, uncertaintyNs: 5_000_000)
        try await writer.close()

        let lines = try String(contentsOf: url).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)

        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(first["frame"] as? Int, 0)
        XCTAssertEqual(first["timestamp_ns"] as? UInt64, 1_000)
        XCTAssertEqual(first["uncertainty_ns"] as? UInt64, 5_000_000)
    }
}
