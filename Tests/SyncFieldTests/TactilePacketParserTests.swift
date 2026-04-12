// Tests/SyncFieldTests/TactilePacketParserTests.swift
import XCTest
@testable import SyncField

final class TactilePacketParserTests: XCTestCase {
    // Build a 3-sample packet manually so we don't depend on device.
    // header: count=3, batch_ts_us=0x01020304
    // samples[0]: [100, 200, 300, 400, 500]
    // samples[1]: [110, 210, 310, 410, 510]
    // samples[2]: [120, 220, 320, 420, 520]
    func test_parses_batch_with_three_samples() throws {
        var bytes: [UInt8] = [
            0x03, 0x00,              // count = 3 (LE)
            0x04, 0x03, 0x02, 0x01,  // batch_ts_us = 0x01020304
        ]
        func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        for base in [UInt16(100), UInt16(110), UInt16(120)] {
            for offset: UInt16 in [0, 100, 200, 300, 400] {
                bytes += u16LE(base + offset)
            }
        }

        let parsed = try TactilePacketParser.parse(Data(bytes))
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.batchTimestampUs, 0x01020304)
        XCTAssertEqual(parsed.samples.count, 3)
        XCTAssertEqual(parsed.samples[0], [100, 200, 300, 400, 500])
        XCTAssertEqual(parsed.samples[2], [120, 220, 320, 420, 520])
    }

    func test_rejects_truncated_packet() {
        let tooShort = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00])  // header only
        XCTAssertThrowsError(try TactilePacketParser.parse(tooShort))
    }

    func test_zero_count_is_empty() throws {
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0]
        let parsed = try TactilePacketParser.parse(Data(bytes))
        XCTAssertEqual(parsed.count, 0)
        XCTAssertEqual(parsed.samples.count, 0)
    }
}
