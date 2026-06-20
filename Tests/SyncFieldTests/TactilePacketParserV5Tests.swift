// Tests/SyncFieldTests/TactilePacketParserV5Tests.swift
import XCTest
@testable import SyncField

/// schema_ver 5 (packed12_v5) parser: 10B header
/// `[count:u8][flags:u8(0x04)][seq_base:u32le][t_base_us:u32le]`, then per-sample
/// `[dt_us:u16le][packed12 taxels][6×i16le raw IMU]`.
final class TactilePacketParserV5Tests: XCTestCase {

    func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    func i16LE(_ v: Int16) -> [UInt8] { u16LE(UInt16(bitPattern: v)) }
    func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Pack `values` (12-bit each, even count) the same way firmware `packTaxels12` does.
    func packTaxels12(_ values: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < values.count {
            let a = values[i] & 0x0FFF
            let b = values[i + 1] & 0x0FFF
            out.append(UInt8(a >> 4))
            out.append(UInt8(((a & 0x0F) << 4) | (b >> 8)))
            out.append(UInt8(b & 0xFF))
            i += 2
        }
        return out
    }

    func imuRaw(_ ax: Int16, _ ay: Int16, _ az: Int16,
                _ gx: Int16, _ gy: Int16, _ gz: Int16) -> [UInt8] {
        i16LE(ax) + i16LE(ay) + i16LE(az) + i16LE(gx) + i16LE(gy) + i16LE(gz)
    }

    // MARK: 12-bit unpack round-trip

    func test_unpackTaxels12_roundtrip() {
        let values: [UInt16] = [0, 1, 4095, 2048, 0x0ABC, 0x0123, 4094, 7]
        let packed = packTaxels12(values)
        XCTAssertEqual(packed.count, values.count / 2 * 3)
        let out = TactilePacketParser.unpackTaxels12(Data(packed), at: 0, count: values.count)
        XCTAssertEqual(out, values)
    }

    // MARK: realistic 412B packet (N=3, 80 taxels, 6-axis IMU)

    func test_parsesV5_realistic_412B_packet() throws {
        let vps = 80
        let count = 3
        let tBase: UInt32 = 1_000_000
        var bytes: [UInt8] = [UInt8(count), 0x04]
        bytes += u32LE(42)             // seq_base
        bytes += u32LE(tBase)          // t_base_us
        for s in 0..<count {
            bytes += u16LE(UInt16(s * 10))                       // dt_us: 0, 10, 20
            let taxels = (0..<vps).map { UInt16((s * 100 + $0) & 0x0FFF) }
            bytes += packTaxels12(taxels)
            bytes += imuRaw(Int16(s + 1), -2, 3, 4, 5, 6)        // ax = s+1
        }
        XCTAssertEqual(bytes.count, 412)

        let p = try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: vps)
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p.seqBase, 42)
        XCTAssertEqual(p.tBaseUs, tBase)
        XCTAssertEqual(p.samples.count, 3)
        XCTAssertEqual(p.samples[0].count, 80)
        XCTAssertEqual(p.samples[0][0], 0)
        XCTAssertEqual(p.samples[2][79], UInt16((279) & 0x0FFF))
        // raw 6-axis IMU per sample
        XCTAssertEqual(p.imu[0]?.ax, 1)
        XCTAssertEqual(p.imu[2]?.ax, 3)
        XCTAssertEqual(p.imu[0]?.gz, 6)
    }

    // MARK: real per-sample device timestamp = t_base_us + dt_us

    func test_per_sample_dt_us_recovered() throws {
        let vps = 4
        let tBase: UInt32 = 500_000
        let dts: [UInt16] = [0, 9, 19]
        var bytes: [UInt8] = [0x03, 0x04]
        bytes += u32LE(0)              // seq_base
        bytes += u32LE(tBase)
        for dt in dts {
            bytes += u16LE(dt)
            bytes += packTaxels12([1, 2, 3, 4])
            bytes += imuRaw(0, 0, 0, 0, 0, 0)
        }
        let p = try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: vps)
        XCTAssertEqual(p.dtUs, dts)
        // Caller computes device_ts = (t_base_us + dt_us); assert the inputs are exact.
        XCTAssertEqual(p.tBaseUs &+ UInt32(p.dtUs[2]), 500_019)
    }

    // MARK: best-effort IMU — truncated trailing IMU keeps taxels

    func test_truncated_imu_keeps_taxels() throws {
        let vps = 4
        var bytes: [UInt8] = [0x02, 0x04]
        bytes += u32LE(0) + u32LE(0)
        // sample 0: full
        bytes += u16LE(0) + packTaxels12([10, 11, 12, 13]) + imuRaw(1, 2, 3, 4, 5, 6)
        // sample 1: dt + taxels present, IMU truncated (only 4 of 12 bytes)
        bytes += u16LE(5) + packTaxels12([20, 21, 22, 23]) + [0x00, 0x00, 0x00, 0x00]

        let p = try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: vps)
        XCTAssertEqual(p.samples[0], [10, 11, 12, 13])
        XCTAssertEqual(p.samples[1], [20, 21, 22, 23])
        XCTAssertNotNil(p.imu[0])
        XCTAssertNil(p.imu[1])        // skipped, not crashed
    }

    // MARK: framing guard — non-0x04 flags rejected

    func test_rejects_non_packed_framing() {
        let vps = 4
        var bytes: [UInt8] = [0x01, 0x02]   // legacy Method C flag, not packed12
        bytes += u32LE(0) + u32LE(0)
        bytes += u16LE(0) + packTaxels12([1, 2, 3, 4]) + imuRaw(0, 0, 0, 0, 0, 0)
        XCTAssertThrowsError(try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: vps)) {
            guard case TactilePacketParser.Error.unsupportedFraming = $0 else {
                return XCTFail("expected unsupportedFraming, got \($0)")
            }
        }
    }

    func test_rejects_short_header() {
        let bytes: [UInt8] = [0x03, 0x04, 0x00, 0x00]   // < 10B header
        XCTAssertThrowsError(try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: 80))
    }

    func test_zero_count_is_empty() throws {
        var bytes: [UInt8] = [0x00, 0x04]
        bytes += u32LE(7) + u32LE(123)
        let p = try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: 80)
        XCTAssertEqual(p.count, 0)
        XCTAssertEqual(p.samples.count, 0)
        XCTAssertEqual(p.tBaseUs, 123)
    }

    func test_rejects_truncated_taxels() {
        let vps = 80
        // claims 2 samples but only carries a partial first slot
        var bytes: [UInt8] = [0x02, 0x04]
        bytes += u32LE(0) + u32LE(0)
        bytes += u16LE(0) + Array(repeating: 0, count: 50)   // far short of one slot
        XCTAssertThrowsError(try TactilePacketParser.parseV5(Data(bytes), valuesPerSample: vps))
    }
}
