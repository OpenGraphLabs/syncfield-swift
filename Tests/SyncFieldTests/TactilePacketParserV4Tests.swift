// Tests/SyncFieldTests/TactilePacketParserV4Tests.swift
import XCTest
@testable import SyncField

/// schema_ver >= 4 parser: [count:u8][flags:u8][base_ts_us:u32le] then per-sample
/// (valuesPerSample × u16le taxels) + optional 17B IMU block.
final class TactilePacketParserV4Tests: XCTestCase {

    func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    func i16LE(_ v: Int16) -> [UInt8] { u16LE(UInt16(bitPattern: v)) }

    func test_parsesV4_with_imu_present() throws {
        let vps = 4
        // header: count=2, flags=0x01 (IMU present), base_ts=0x000F4240 (1_000_000)
        var bytes: [UInt8] = [0x02, 0x01, 0x40, 0x42, 0x0F, 0x00]
        // sample 0 taxels + imu
        bytes += u16LE(11) + u16LE(12) + u16LE(13) + u16LE(14)
        bytes += i16LE(100) + i16LE(-200)        // roll, pitch
        bytes += i16LE(1) + i16LE(2) + i16LE(3)  // ax, ay, az
        bytes += i16LE(4) + i16LE(5) + i16LE(6)  // gx, gy, gz
        bytes += [0x01]                          // imu_ok = true
        // sample 1 taxels + imu
        bytes += u16LE(21) + u16LE(22) + u16LE(23) + u16LE(24)
        bytes += i16LE(7) + i16LE(8)
        bytes += i16LE(9) + i16LE(10) + i16LE(11)
        bytes += i16LE(12) + i16LE(13) + i16LE(14)
        bytes += [0x00]                          // imu_ok = false

        let p = try TactilePacketParser.parseV4(Data(bytes), valuesPerSample: vps)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p.batchTimestampUs, 1_000_000)
        XCTAssertEqual(p.samples[0], [11, 12, 13, 14])
        XCTAssertEqual(p.samples[1], [21, 22, 23, 24])
        XCTAssertEqual(p.imu[0]?.rollCdeg, 100)
        XCTAssertEqual(p.imu[0]?.pitchCdeg, -200)
        XCTAssertEqual(p.imu[0]?.gz, 6)
        XCTAssertEqual(p.imu[0]?.ok, true)
        XCTAssertEqual(p.imu[1]?.ok, false)
    }

    func test_parsesV4_without_imu() throws {
        let vps = 3
        // count=1, flags=0x00 (no IMU), base_ts=0
        var bytes: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += u16LE(1000) + u16LE(2000) + u16LE(3000)

        let p = try TactilePacketParser.parseV4(Data(bytes), valuesPerSample: vps)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.samples[0], [1000, 2000, 3000])
        XCTAssertNil(p.imu[0])
    }

    func test_parsesV4_real_packet_geometry_80_taxel_with_imu() throws {
        // Mirrors the live device: 2 samples, 80 taxels + IMU = 6 + 2*177 = 360 bytes.
        let vps = 80
        var bytes: [UInt8] = [0x02, 0x01, 0x00, 0x00, 0x00, 0x00]
        for s in 0..<2 {
            for t in 0..<vps { bytes += u16LE(UInt16(s * 100 + t)) }
            bytes += Array(repeating: 0, count: 17)  // imu block
        }
        XCTAssertEqual(bytes.count, 360)
        let p = try TactilePacketParser.parseV4(Data(bytes), valuesPerSample: vps)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p.samples[0].count, 80)
        XCTAssertEqual(p.samples[1][79], 179)
        XCTAssertNotNil(p.imu[0])
    }

    func test_rejects_short_v4_packet() {
        let bytes: [UInt8] = [0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]  // claims 2 samples, has none
        XCTAssertThrowsError(try TactilePacketParser.parseV4(Data(bytes), valuesPerSample: 80))
    }

    // Legacy 5-FSR parser must remain byte-identical (regression anchor).
    func test_legacy_parser_unchanged() throws {
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        var bytes: [UInt8] = [0x01, 0x00, 0x04, 0x03, 0x02, 0x01]
        for v: UInt16 in [10, 20, 30, 40, 50] { bytes += u16(v) }
        let p = try TactilePacketParser.parse(Data(bytes))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.batchTimestampUs, 0x01020304)
        XCTAssertEqual(p.samples[0], [10, 20, 30, 40, 50])
    }
}
