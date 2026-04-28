// Tests/SyncFieldTests/Quality/EventWriterTests.swift
import XCTest
@testable import SyncField

final class EventWriterTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-writer-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func test_intervalRoundTrip_writesOneCompleteRecord() async throws {
        let url = tmpDir.appendingPathComponent("events.jsonl")
        let writer = EventWriter(fileURL: url)
        let handle = try await writer.appendIntervalStart(
            kind: "hand_out_of_frame",
            startMonotonicNs: 1_000_000_000,
            startFrame: 10,
            payload: ["hand": "left"]
        )
        try await writer.closeInterval(handle: handle, endMonotonicNs: 2_000_000_000, endFrame: 20)
        await writer.flush()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        let json = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(json["kind"] as? String, "hand_out_of_frame")
        XCTAssertEqual((json["start_monotonic_ns"] as? NSNumber)?.uint64Value, 1_000_000_000)
        XCTAssertEqual((json["end_monotonic_ns"] as? NSNumber)?.uint64Value, 2_000_000_000)
        XCTAssertEqual(json["stream_id"] as? String, "cam_ego")
        let payload = json["payload"] as! [String: Any]
        XCTAssertEqual(payload["hand"] as? String, "left")
        XCTAssertEqual(payload["frame_start"] as? Int, 10)
        XCTAssertEqual(payload["frame_end"] as? Int, 20)
    }

    func test_pointEvent_writesStartEqualsEnd() async throws {
        let url = tmpDir.appendingPathComponent("events.jsonl")
        let writer = EventWriter(fileURL: url)
        try await writer.appendPoint(
            kind: "audio_cue_route_set",
            monotonicNs: 5_000_000_000,
            payload: ["route": "Bluetooth"]
        )
        await writer.flush()

        let raw = try String(contentsOf: url, encoding: .utf8)
        let line = raw.split(separator: "\n").first!
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual((json["start_monotonic_ns"] as? NSNumber)?.uint64Value, 5_000_000_000)
        XCTAssertEqual((json["end_monotonic_ns"] as? NSNumber)?.uint64Value, 5_000_000_000)
    }

    func test_finalize_truncatesOpenIntervals() async throws {
        let url = tmpDir.appendingPathComponent("events.jsonl")
        let writer = EventWriter(fileURL: url)
        _ = try await writer.appendIntervalStart(
            kind: "hand_out_of_frame",
            startMonotonicNs: 1_000_000_000,
            startFrame: 10,
            payload: ["hand": "left"]
        )
        try await writer.finalize(stopMonotonicNs: 9_999_999_999, stopFrame: 99)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        let json = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual((json["end_monotonic_ns"] as? NSNumber)?.uint64Value, 9_999_999_999)
        let payload = json["payload"] as! [String: Any]
        XCTAssertEqual(payload["_truncated_at_stop"] as? Bool, true)
        XCTAssertEqual(payload["frame_end"] as? Int, 99)
    }

    func test_jsonlIsLineGreppable() async throws {
        let url = tmpDir.appendingPathComponent("events.jsonl")
        let writer = EventWriter(fileURL: url)
        for i in 0..<5 {
            try await writer.appendPoint(
                kind: "qa_audio_cue",
                monotonicNs: UInt64(i) * 1_000_000_000,
                payload: ["cue": "left_warning"]
            )
        }
        await writer.flush()
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }
}
