// Sources/SyncField/Streams/Tactile/TactileTypes.swift
import Foundation

public enum TactileSide: String, Codable, Sendable {
    case left, right
}

public enum TactileConstants {
    public static let serviceUUID    = UUID(uuidString: "4652535F-424C-4500-0000-000000000001")!
    public static let sensorCharUUID = UUID(uuidString: "4652535F-424C-4500-0001-000000000001")!
    public static let configCharUUID = UUID(uuidString: "4652535F-424C-4500-0002-000000000001")!
    // Reserved for future use. NOT written at runtime — command writes were observed
    // to destabilise the BLE link, so the stream is consumed at the firmware default
    // and never reconfigured at runtime.
    public static let commandCharUUID = UUID(uuidString: "4652535F-424C-4500-0003-000000000001")!
    public static let logCharUUID     = UUID(uuidString: "4652535F-424C-4500-0004-000000000001")!
    public static let nameFilter = "oglo"
    public static let canonicalFingerOrder = ["thumb", "index", "middle", "ring", "pinky"]

    // --- schema_ver 5 (packed12_v5): the only supported OGLO wire format ---
    // Firmware FW >= 0.7.0 (golden 0.7.1-cfgfit). Packed 12-bit taxels + per-sample
    // RAW 6-axis IMU, with a real per-sample device timestamp.
    //
    // Header (10B): [count:u8][flags:u8(0x04)][seq_base:u32le][t_base_us:u32le]
    // Per sample (stride 134B for 80 taxels):
    //   [dt_us:u16le][80 × 12-bit packed taxels = 120B][6 × i16le raw IMU = 12B]
    // Firmware source of truth: oglo-hardware/firmware/OGLO-MT-RDR-02/oglo_rdr02_ble/oglo_rdr02_ble.ino
    // (BLE_FLAG_PACKED, packTaxels12, putImuRaw, PKD_SAMPLE_STRIDE).
    public static let schemaVer = 5
    public static let v5HeaderBytes = 10
    public static let v5TaxelPackedBytes = 120        // 80 taxels × 12-bit, packed 2-per-3-bytes
    public static let v5ImuRawBytes = 12              // ax,ay,az,gx,gy,gz (6 × i16le)
    public static let v5SampleStride = 2 + v5TaxelPackedBytes + v5ImuRawBytes  // 134
    public static let v5FlagPacked: UInt8 = 0x04
    public static let defaultValuesPerSample = 80     // 5 fingers × 4 rows × 4 cols
}

/// Firmware config blob read from the config characteristic (schema_ver 5).
///
/// `channels` is a flat array of side-aware finger-name strings
/// (e.g. `["pinky","ring","middle","index","thumb"]`); `fingerLabels` exposes that
/// order (falling back to `canonicalFingerOrder`). Unknown JSON keys are ignored.
public struct DeviceManifest: Codable, Sendable {
    public let device: String
    public let side: TactileSide
    public let schemaVer: Int
    public let packetFormat: String?
    public let rateHz: Int
    public let valuesPerSample: Int?
    public let samplesPerPacket: Int?
    public let sampleShape: [Int]?
    /// Ordered finger names from the manifest `channels` array.
    public let fingerLabels: [String]

    enum CodingKeys: String, CodingKey {
        case device
        case side
        case schemaVer = "schema_ver"
        case packetFormat = "packet_format"
        case rateHz = "rate_hz"
        case valuesPerSample = "values_per_sample"
        case samplesPerPacket = "samples_per_packet"
        case sampleShape = "sample_shape"
        case channels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(String.self, forKey: .device)
        side = try c.decode(TactileSide.self, forKey: .side)
        schemaVer = try c.decodeIfPresent(Int.self, forKey: .schemaVer) ?? 0
        packetFormat = try c.decodeIfPresent(String.self, forKey: .packetFormat)
        rateHz = try c.decodeIfPresent(Int.self, forKey: .rateHz) ?? 100
        valuesPerSample = try c.decodeIfPresent(Int.self, forKey: .valuesPerSample)
        samplesPerPacket = try c.decodeIfPresent(Int.self, forKey: .samplesPerPacket)
        sampleShape = try c.decodeIfPresent([Int].self, forKey: .sampleShape)
        let strs = try c.decodeIfPresent([String].self, forKey: .channels)
        fingerLabels = (strs?.isEmpty == false) ? strs! : TactileConstants.canonicalFingerOrder
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(device, forKey: .device)
        try c.encode(side, forKey: .side)
        try c.encode(schemaVer, forKey: .schemaVer)
        try c.encodeIfPresent(packetFormat, forKey: .packetFormat)
        try c.encode(rateHz, forKey: .rateHz)
        try c.encodeIfPresent(valuesPerSample, forKey: .valuesPerSample)
        try c.encodeIfPresent(samplesPerPacket, forKey: .samplesPerPacket)
        try c.encodeIfPresent(sampleShape, forKey: .sampleShape)
        try c.encode(fingerLabels, forKey: .channels)
    }

    /// Test/utility initialiser.
    public init(device: String, side: TactileSide, schemaVer: Int,
                rateHz: Int = 100, packetFormat: String? = "packed12_v5",
                valuesPerSample: Int? = 80, samplesPerPacket: Int? = nil,
                sampleShape: [Int]? = [5, 4, 4], fingerLabels: [String]? = nil) {
        self.device = device
        self.side = side
        self.schemaVer = schemaVer
        self.packetFormat = packetFormat
        self.rateHz = rateHz
        self.valuesPerSample = valuesPerSample
        self.samplesPerPacket = samplesPerPacket
        self.sampleShape = sampleShape
        self.fingerLabels = fingerLabels ?? TactileConstants.canonicalFingerOrder
    }
}
