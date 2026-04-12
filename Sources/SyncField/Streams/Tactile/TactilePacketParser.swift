// Sources/SyncField/Streams/Tactile/TactilePacketParser.swift
import Foundation

public struct TactilePacket: Sendable {
    public let count: Int
    public let batchTimestampUs: UInt32
    public let samples: [[UInt16]]   // [sample_index][channel_index]
}

public enum TactilePacketParser {
    public enum Error: Swift.Error { case truncated, sizeMismatch }

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
    private static func u16LE(_ d: Data, offset: Int) -> UInt16 {
        UInt16(d[d.startIndex + offset]) | (UInt16(d[d.startIndex + offset + 1]) << 8)
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
