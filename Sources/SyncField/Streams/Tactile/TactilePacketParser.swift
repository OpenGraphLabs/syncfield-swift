// Sources/SyncField/Streams/Tactile/TactilePacketParser.swift
import Foundation

public struct TactilePacket: Sendable {
    public let count: Int
    public let batchTimestampUs: UInt32
    public let samples: [[UInt16]]   // [sample_index][channel_index]
}

/// Per-sample IMU block carried by schema_ver >= 4 packets.
public struct TactileImuSample: Sendable {
    public let rollCdeg: Int16
    public let pitchCdeg: Int16
    public let ax: Int16
    public let ay: Int16
    public let az: Int16
    public let gx: Int16
    public let gy: Int16
    public let gz: Int16
    public let ok: Bool
}

/// schema_ver >= 4 packet: taxel matrix per sample, with IMU in one of two framings.
public struct TactilePacketV4: Sendable {
    public let count: Int
    public let batchTimestampUs: UInt32
    public let samples: [[UInt16]]          // [sample_index][taxel_index] — length valuesPerSample
    public let imu: [TactileImuSample?]      // Method B: parallel to samples; nil when absent
    /// Method C: a single packet-level IMU sample for the whole notify batch
    /// (sample slots are taxels-only). nil when the packet carries no packet-level IMU.
    public let packetImu: TactileImuSample?
}

public enum TactilePacketParser {
    public enum Error: Swift.Error { case truncated, sizeMismatch }

    /// Parse a schema_ver >= 4 packet. Header is [count:u8][flags:u8][base_ts_us:u32le].
    /// IMU comes in one of two mutually-exclusive framings (firmware decides per-packet):
    ///   • Method B (flags bit0): each sample is `valuesPerSample` u16le taxels + a 17B IMU block.
    ///   • Method C (flags bit1): each sample is taxels-only, then ONE 17B IMU block after all samples.
    /// Taxels are always parsed first; the IMU is decoded best-effort so a truncated or
    /// absent IMU block never drops the taxel payload.
    public static func parseV4(_ data: Data, valuesPerSample: Int) throws -> TactilePacketV4 {
        guard data.count >= TactileConstants.v4HeaderBytes else { throw Error.truncated }

        let count = Int(byte(data, 0))
        let flags = byte(data, 1)
        let batchTsUs = u32LE(data, offset: 2)
        let perSampleImu = (flags & TactileConstants.v4FlagImuPresent) != 0  // Method B
        let packetImuFlag = (flags & TactileConstants.v4FlagPacketImu) != 0  // Method C
        let imuLen = perSampleImu ? TactileConstants.v4ImuBytes : 0
        let stride = valuesPerSample * 2 + imuLen

        // Taxels must be fully present. (Method C's trailing packet-level IMU is
        // decoded best-effort below and never gates this guard.)
        let taxelExpected = TactileConstants.v4HeaderBytes + count * stride
        guard data.count >= taxelExpected else { throw Error.sizeMismatch }

        var samples: [[UInt16]] = []
        var imuOut: [TactileImuSample?] = []
        samples.reserveCapacity(count)
        imuOut.reserveCapacity(count)

        for s in 0..<count {
            let base = TactileConstants.v4HeaderBytes + s * stride
            var taxels: [UInt16] = []
            taxels.reserveCapacity(valuesPerSample)
            for c in 0..<valuesPerSample {
                taxels.append(u16LE(data, offset: base + c * 2))
            }
            samples.append(taxels)

            if perSampleImu {
                imuOut.append(decodeImu(data, at: base + valuesPerSample * 2))
            } else {
                imuOut.append(nil)
            }
        }

        // Method C: one packet-level IMU block after all taxel samples. Best-effort
        // — only decode when the bytes are actually present.
        var packetImu: TactileImuSample? = nil
        if packetImuFlag {
            let imuOffset = TactileConstants.v4HeaderBytes + count * stride
            if data.count >= imuOffset + TactileConstants.v4ImuBytes {
                packetImu = decodeImu(data, at: imuOffset)
            }
        }

        return TactilePacketV4(count: count, batchTimestampUs: batchTsUs,
                               samples: samples, imu: imuOut, packetImu: packetImu)
    }

    /// Decode a 17B IMU block: roll,pitch,ax,ay,az,gx,gy,gz (8×i16le) + ok(u8).
    @inline(__always)
    private static func decodeImu(_ d: Data, at i: Int) -> TactileImuSample {
        TactileImuSample(
            rollCdeg: i16LE(d, offset: i + 0),
            pitchCdeg: i16LE(d, offset: i + 2),
            ax: i16LE(d, offset: i + 4),
            ay: i16LE(d, offset: i + 6),
            az: i16LE(d, offset: i + 8),
            gx: i16LE(d, offset: i + 10),
            gy: i16LE(d, offset: i + 12),
            gz: i16LE(d, offset: i + 14),
            ok: byte(d, i + 16) != 0)
    }

    public static func parse(_ data: Data) throws -> TactilePacket {
        guard data.count >= TactileConstants.packetHeaderBytes else { throw Error.truncated }

        let count = Int(u16LE(data, offset: 0))
        let batchTsUs = u32LE(data, offset: 2)

        let expected = TactileConstants.packetHeaderBytes
            + count * TactileConstants.bytesPerSample
        guard data.count >= expected else { throw Error.sizeMismatch }

        var samples: [[UInt16]] = []
        samples.reserveCapacity(count)
        for s in 0..<count {
            let base = TactileConstants.packetHeaderBytes + s * TactileConstants.bytesPerSample
            var channels: [UInt16] = []
            channels.reserveCapacity(TactileConstants.channelsPerSample)
            for c in 0..<TactileConstants.channelsPerSample {
                channels.append(u16LE(data, offset: base + c * 2))
            }
            samples.append(channels)
        }

        return TactilePacket(count: count, batchTimestampUs: batchTsUs, samples: samples)
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
