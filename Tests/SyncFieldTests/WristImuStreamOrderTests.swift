import XCTest
@testable import SyncField

/// JSONL write-order + drain guarantees for the OGLO glove streams.
///
/// The BLE notify path appends at ~100 Hz; rows must land in append order and
/// `stopRecording()` must drain every in-flight row before closing the file.
/// The earlier per-sample unstructured-Task pattern violated both: production
/// episode ep_20260727_115106 shipped 18 out-of-order rows in
/// tactile_left.jsonl, and rows appended just before stop raced the close.
final class WristImuStreamOrderTests: XCTestCase {
    private func makeEpisodeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrist-imu-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRowsLandInAppendOrderAndStopDrainsEveryRow() async throws {
        let dir = try makeEpisodeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = WristImuStream(streamId: "wrist_imu_left")
        try await stream.startRecording(
            clock: SessionClock(),
            writerFactory: WriterFactory(episodeDirectory: dir))

        let total = 500
        for i in 0..<total {
            stream.append(
                captureNs: UInt64(1_000_000 * i),
                deviceTimestampNs: UInt64(10_000 * i),
                channels: ["ax": i, "ay": 0, "az": 0, "gx": 0, "gy": 0, "gz": 0])
        }
        let report = try await stream.stopRecording()

        XCTAssertEqual(report.frameCount, total)

        let text = try String(
            contentsOf: dir.appendingPathComponent("wrist_imu_left.jsonl"),
            encoding: .utf8)
        let rows = text.split(separator: "\n").map { line -> Int in
            let obj = try! JSONSerialization.jsonObject(
                with: Data(line.utf8)) as! [String: Any]
            return obj["frame_number"] as! Int
        }
        // Every appended row is on disk (stop drained the queue before close)…
        XCTAssertEqual(rows.count, total, "stopRecording lost in-flight rows")
        // …and in exactly the order it was appended.
        XCTAssertEqual(rows, Array(0..<total), "rows landed out of order")
    }
}
