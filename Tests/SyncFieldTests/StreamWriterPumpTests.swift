import Foundation
import XCTest
@testable import SyncField

final class StreamWriterPumpTests: XCTestCase {
    func testPumpPreservesFrameOrderAndFlushesBeforeClose() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-writer-pump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("cam_ego.timestamps.jsonl")
        let writer = try StreamWriter(url: url)
        let pump = StreamWriterPump(label: "syncfield.tests.stream-writer-pump")
        for frame in 0..<100 {
            pump.append(
                writer: writer, frame: frame,
                monotonicNs: UInt64(frame), uncertaintyNs: 1)
        }

        pump.flush()
        try await writer.close()

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        for (index, line) in lines.enumerated() {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(object?["frame_number"] as? Int, index)
        }
    }
}
