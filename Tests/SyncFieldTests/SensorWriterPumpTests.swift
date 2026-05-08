import Foundation
import XCTest
@testable import SyncField

final class SensorWriterPumpTests: XCTestCase {
    func test_pump_preserves_enqueue_order_and_flushes_before_close() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-pump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("imu_accel_raw.jsonl")
        let writer = try SensorWriter(url: url)
        let pump = SensorWriterPump(label: "syncfield.tests.writer-pump")

        for frame in 0..<100 {
            pump.append(
                writer: writer,
                frame: frame,
                monotonicNs: UInt64(frame),
                channels: ["value": frame]
            )
        }

        pump.flush()
        try await writer.close()

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        for (idx, line) in lines.enumerated() {
            let data = Data(line.utf8)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(obj?["frame_number"] as? Int, idx)
        }
    }
}
