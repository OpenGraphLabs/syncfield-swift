// Sources/SyncField/Streams/Tactile/TactileTypes.swift
import Foundation

public enum TactileSide: String, Codable, Sendable {
    case left, right
}

public enum TactileConstants {
    public static let serviceUUID    = UUID(uuidString: "4652535F-424C-4500-0000-000000000001")!
    public static let sensorCharUUID = UUID(uuidString: "4652535F-424C-4500-0001-000000000001")!
    public static let configCharUUID = UUID(uuidString: "4652535F-424C-4500-0002-000000000001")!
    // Reserved for future use (firmware schema_ver=4 exposes these). NOT written in v1 —
    // runtime command writes were observed to destabilise the BLE link, so the stream is
    // consumed at the firmware default and never reconfigured at runtime.
    public static let commandCharUUID = UUID(uuidString: "4652535F-424C-4500-0003-000000000001")!
    public static let logCharUUID     = UUID(uuidString: "4652535F-424C-4500-0004-000000000001")!
    public static let nameFilter = "oglo"
    public static let canonicalFingerOrder = ["thumb", "index", "middle", "ring", "pinky"]

    // --- schema_ver < 4 (legacy 5-FSR) ---
    public static let packetHeaderBytes = 6
    public static let channelsPerSample = 5
    public static let bytesPerSample    = channelsPerSample * 2  // 10
    public static let sampleIntervalUs: UInt32 = 10_000          // 100 Hz nominal

    // --- schema_ver >= 4 (taxel matrix + IMU) ---
    // Header is the same 6 bytes but interpreted as [count:u8][flags:u8][base_ts_us:u32le].
    // Two IMU framings (firmware decides per-packet via the flags byte):
    //   • Method B (bit0): every sample slot carries its own 17B IMU block.
    //   • Method C (bit1, FW >= 0.6.5): sample slots are taxels-only, followed by
    //     ONE packet-level 17B IMU block after all samples (lower notify pressure).
    // Parsers must accept both; they are mutually exclusive on the wire.
    public static let v4HeaderBytes = 6
    public static let v4ImuBytes    = 17           // roll,pitch,ax,ay,az,gx,gy,gz (8×i16) + imu_ok(u8)
    public static let v4FlagImuPresent: UInt8 = 0x01  // Method B: per-sample IMU
    public static let v4FlagPacketImu: UInt8  = 0x02  // Method C: one packet-level IMU block
    public static let v4DefaultValuesPerSample = 80 // 5 fingers × 4 rows × 4 cols
}

/// Firmware config blob read from the config characteristic.
///
/// Tolerant of two on-wire shapes:
///   • legacy (schema_ver < 4): `channels` is an array of `{id, loc, type, bits}` objects.
///   • schema_ver >= 4: `channels` is a flat array of finger-name strings
///     (e.g. `["pinky","ring","middle","index","thumb"]`), plus `values_per_sample`,
///     `sample_shape`, `sample_order`.
///
/// `fingerLabels` is the normalised finger order regardless of input shape.
public struct DeviceManifest: Codable, Sendable {
    public struct Channel: Codable, Sendable {
        public let id: Int
        public let loc: String
        public let type: String
        public let bits: Int
    }

    public let device: String
    public let side: TactileSide
    public let hwRev: String?
    public let rateHz: Int
    /// Legacy object channels; empty for schema_ver >= 4.
    public let channels: [Channel]

    // schema_ver >= 4 fields (nil/0 on legacy firmware)
    public let schemaVer: Int
    public let valuesPerSample: Int?
    public let samplesPerPacket: Int?
    public let sampleShape: [Int]?
    public let sampleOrder: String?
    /// Ordered finger names. From legacy `channels[*].loc`, from v4 string `channels`,
    /// or `canonicalFingerOrder` as a last resort.
    public let fingerLabels: [String]

    /// Label for a legacy FSR channel id, or the finger name at `id` for v4.
    public func locationForChannel(_ id: Int) -> String? {
        if !channels.isEmpty { return channels.first(where: { $0.id == id })?.loc }
        if id >= 0 && id < fingerLabels.count { return fingerLabels[id] }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case device
        case side
        case hwRev = "hw_rev"
        case rateHz = "rate_hz"
        case channels
        case schemaVer = "schema_ver"
        case valuesPerSample = "values_per_sample"
        case samplesPerPacket = "samples_per_packet"
        case sampleShape = "sample_shape"
        case sampleOrder = "sample_order"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(String.self, forKey: .device)
        side = try c.decode(TactileSide.self, forKey: .side)
        hwRev = try c.decodeIfPresent(String.self, forKey: .hwRev)
        rateHz = try c.decodeIfPresent(Int.self, forKey: .rateHz) ?? 100
        schemaVer = try c.decodeIfPresent(Int.self, forKey: .schemaVer) ?? 0
        valuesPerSample = try c.decodeIfPresent(Int.self, forKey: .valuesPerSample)
        samplesPerPacket = try c.decodeIfPresent(Int.self, forKey: .samplesPerPacket)
        sampleShape = try c.decodeIfPresent([Int].self, forKey: .sampleShape)
        sampleOrder = try c.decodeIfPresent(String.self, forKey: .sampleOrder)

        // `channels` may be objects (legacy) or strings (v4).
        if let objs = try? c.decode([Channel].self, forKey: .channels) {
            channels = objs
            fingerLabels = objs.map { $0.loc }
        } else if let strs = try? c.decode([String].self, forKey: .channels) {
            channels = []
            fingerLabels = strs
        } else {
            channels = []
            fingerLabels = TactileConstants.canonicalFingerOrder
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(device, forKey: .device)
        try c.encode(side, forKey: .side)
        try c.encodeIfPresent(hwRev, forKey: .hwRev)
        try c.encode(rateHz, forKey: .rateHz)
        if schemaVer != 0 { try c.encode(schemaVer, forKey: .schemaVer) }
        try c.encodeIfPresent(valuesPerSample, forKey: .valuesPerSample)
        try c.encodeIfPresent(samplesPerPacket, forKey: .samplesPerPacket)
        try c.encodeIfPresent(sampleShape, forKey: .sampleShape)
        try c.encodeIfPresent(sampleOrder, forKey: .sampleOrder)
        if !channels.isEmpty {
            try c.encode(channels, forKey: .channels)
        } else {
            try c.encode(fingerLabels, forKey: .channels)
        }
    }

    /// Test/utility initialiser.
    public init(device: String, side: TactileSide, hwRev: String?, rateHz: Int,
                channels: [Channel], schemaVer: Int = 0, valuesPerSample: Int? = nil,
                samplesPerPacket: Int? = nil, sampleShape: [Int]? = nil,
                sampleOrder: String? = nil, fingerLabels: [String]? = nil) {
        self.device = device
        self.side = side
        self.hwRev = hwRev
        self.rateHz = rateHz
        self.channels = channels
        self.schemaVer = schemaVer
        self.valuesPerSample = valuesPerSample
        self.samplesPerPacket = samplesPerPacket
        self.sampleShape = sampleShape
        self.sampleOrder = sampleOrder
        self.fingerLabels = fingerLabels ?? channels.map { $0.loc }
    }
}
