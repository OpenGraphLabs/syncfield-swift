// Sources/SyncField/Streams/Tactile/TactilePacketParser.swift
import Foundation

/// Per-sample RAW 6-axis IMU carried by schema_ver 5 (packed12_v5) packets.
/// Values are uncalibrated device LSB (ICM-42688-P: accel ±8g, gyro ±2000 dps).
public struct TactileRawImuSample: Sendable {
    public let ax: Int16
    public let ay: Int16
    public let az: Int16
    public let gx: Int16
    public let gy: Int16
    public let gz: Int16
}

/// A parsed schema_ver 5 packet: a packed 12-bit taxel matrix plus a per-sample
/// raw IMU, each tagged with a real per-sample device timestamp (`t_base_us + dt_us`).
public struct TactilePacketV5: Sendable {
    public let count: Int
    public let seqBase: UInt32
    public let tBaseUs: UInt32
    public let samples: [[UInt16]]            // [sample_index][taxel_index], values 0–4095
    public let dtUs: [UInt16]                 // per-sample delta from tBaseUs (sample 0 = 0)
    public let imu: [TactileRawImuSample?]    // per-sample raw IMU; nil if its bytes are truncated
}

public enum TactilePacketParser {
    public enum Error: Swift.Error { case truncated, sizeMismatch, unsupportedFraming(UInt8) }

    /// Parse a schema_ver 5 (packed12_v5) packet.
    ///
    /// Header (10B): `[count:u8][flags:u8][seq_base:u32le][t_base_us:u32le]`.
    /// Per sample (stride `2 + packed12(vps) + 12`): `[dt_us:u16le][packed12 taxels][6×i16le raw IMU]`.
    ///
    /// Taxels are parsed first; each sample's IMU is decoded best-effort, so a
    /// truncated trailing IMU block never drops the taxel payload (firmware↔parser
    /// contract). Throws `unsupportedFraming` if the packed-12 flag (0x04) is unset —
    /// schema_ver 5 is the only OGLO wire format this parser accepts.
    public static func parseV5(_ data: Data, valuesPerSample: Int) throws -> TactilePacketV5 {
        guard data.count >= TactileConstants.v5HeaderBytes else { throw Error.truncated }

        let count = Int(byte(data, 0))
        let flags = byte(data, 1)
        guard (flags & TactileConstants.v5FlagPacked) != 0 else {
            throw Error.unsupportedFraming(flags)
        }
        let seqBase = u32LE(data, offset: 2)
        let tBaseUs = u32LE(data, offset: 6)

        guard count > 0 else {
            return TactilePacketV5(count: 0, seqBase: seqBase, tBaseUs: tBaseUs,
                                   samples: [], dtUs: [], imu: [])
        }

        let packedBytes = (valuesPerSample * 3) / 2     // 2 taxels per 3 bytes (12-bit)
        let taxelSlot = 2 + packedBytes                 // dt_us + packed taxels
        let stride = taxelSlot + TactileConstants.v5ImuRawBytes

        // Taxels (dt_us + packed taxels) for every sample must be fully present; only
        // the final sample's IMU may be truncated. IMU is decoded best-effort below.
        let taxelExpected = TactileConstants.v5HeaderBytes + (count - 1) * stride + taxelSlot
        guard data.count >= taxelExpected else { throw Error.sizeMismatch }

        var samples: [[UInt16]] = []
        var dtOut: [UInt16] = []
        var imuOut: [TactileRawImuSample?] = []
        samples.reserveCapacity(count)
        dtOut.reserveCapacity(count)
        imuOut.reserveCapacity(count)

        for s in 0..<count {
            let base = TactileConstants.v5HeaderBytes + s * stride
            dtOut.append(u16LE(data, offset: base))
            samples.append(unpackTaxels12(data, at: base + 2, count: valuesPerSample))

            let imuBase = base + taxelSlot
            if data.count >= imuBase + TactileConstants.v5ImuRawBytes {
                imuOut.append(decodeRawImu(data, at: imuBase))
            } else {
                imuOut.append(nil)
            }
        }

        return TactilePacketV5(count: count, seqBase: seqBase, tBaseUs: tBaseUs,
                               samples: samples, dtUs: dtOut, imu: imuOut)
    }

    /// Unpack `count` 12-bit taxels packed 2-per-3-bytes (triplet form), mirroring
    /// firmware `packTaxels12`. Each returned value is in `[0, 4095]`.
    static func unpackTaxels12(_ d: Data, at offset: Int, count: Int) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(count)
        var k = 0
        while out.count < count {
            let b0 = UInt16(byte(d, offset + 3 * k + 0))
            let b1 = UInt16(byte(d, offset + 3 * k + 1))
            let b2 = UInt16(byte(d, offset + 3 * k + 2))
            out.append((b0 << 4) | (b1 >> 4))            // even taxel
            if out.count < count {
                out.append(((b1 & 0x0F) << 8) | b2)      // odd taxel
            }
            k += 1
        }
        return out
    }

    /// Decode a 12B raw IMU block: ax,ay,az,gx,gy,gz (6 × i16le).
    @inline(__always)
    private static func decodeRawImu(_ d: Data, at i: Int) -> TactileRawImuSample {
        TactileRawImuSample(
            ax: i16LE(d, offset: i + 0),
            ay: i16LE(d, offset: i + 2),
            az: i16LE(d, offset: i + 4),
            gx: i16LE(d, offset: i + 6),
            gy: i16LE(d, offset: i + 8),
            gz: i16LE(d, offset: i + 10))
    }

    @inline(__always)
    private static func byte(_ d: Data, _ offset: Int) -> UInt8 {
        d[d.startIndex + offset]
    }

    @inline(__always)
    private static func u16LE(_ d: Data, offset: Int) -> UInt16 {
        UInt16(d[d.startIndex + offset]) | (UInt16(d[d.startIndex + offset + 1]) << 8)
    }

    @inline(__always)
    private static func i16LE(_ d: Data, offset: Int) -> Int16 {
        Int16(bitPattern: u16LE(d, offset: offset))
    }

    @inline(__always)
    private static func u32LE(_ d: Data, offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(d[d.startIndex + offset + i]) << (8 * i)
        }
        return v
    }
}
