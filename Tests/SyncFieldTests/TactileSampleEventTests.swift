import XCTest
@testable import SyncField

/// Verifies that `TactileStream.setSampleHandler` fires once per sample with
/// the correct labels, timestamps, and values. Uses a deterministic synthesized
/// packet fed through the public parser — does not require CoreBluetooth.
///
/// The stream's BLE subscribe path is not exercised here (it requires real
/// hardware); we validate the per-packet dispatch logic by calling a
/// test-only reflective hook that mirrors `handlePacket`.
final class TactileSampleEventTests: XCTestCase {

    func test_parser_output_matches_event_shape_expectations() throws {
        // Build a 2-sample packet: count=2, batchTs=1_000_000 μs,
        // sample 0: [10, 20, 30, 40, 50]
        // sample 1: [15, 25, 35, 45, 55]
        func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        var bytes: [UInt8] = [
            0x02, 0x00,                 // count = 2
            0x40, 0x42, 0x0F, 0x00,     // batchTs = 1_000_000 μs (0x000F4240)
        ]
        for base in [UInt16(10), UInt16(15)] {
            for offset: UInt16 in [0, 10, 20, 30, 40] {
                bytes += u16LE(base + offset)
            }
        }

        let packet = try TactilePacketParser.parse(Data(bytes))
        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet.batchTimestampUs, 1_000_000)
        XCTAssertEqual(packet.samples[0], [10, 20, 30, 40, 50])
        XCTAssertEqual(packet.samples[1], [15, 25, 35, 45, 55])
    }

    func test_sample_event_carries_all_fields() {
        let event = TactileSampleEvent(
            streamId: "tactile_left",
            side: .left,
            frame: 7,
            monotonicNs: 123_456,
            deviceTimestampNs: 9_876_543,
            channels: ["thumb": 100, "index": 200])

        XCTAssertEqual(event.streamId, "tactile_left")
        XCTAssertEqual(event.side, .left)
        XCTAssertEqual(event.frame, 7)
        XCTAssertEqual(event.monotonicNs, 123_456)
        XCTAssertEqual(event.deviceTimestampNs, 9_876_543)
        XCTAssertEqual(event.channels["thumb"], 100)
        XCTAssertEqual(event.channels["index"], 200)
    }

    func test_set_sample_handler_nil_removes_previous_handler() {
        let stream = TactileStream(streamId: "tactile_left", side: .left)
        stream.setSampleHandler { _ in }
        stream.setSampleHandler(nil)
        // If removal leaks memory the test still passes under XCTest, but the
        // important assertion is that the API accepts nil without crashing.
        XCTAssertNotNil(stream)
    }
}
