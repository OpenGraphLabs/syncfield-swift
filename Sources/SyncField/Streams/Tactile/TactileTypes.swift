// Sources/SyncField/Streams/Tactile/TactileTypes.swift
import Foundation

public enum TactileSide: String, Codable, Sendable {
    case left, right
}

public enum TactileConstants {
    public static let serviceUUID    = UUID(uuidString: "4652535F-424C-4500-0000-000000000001")!
    public static let sensorCharUUID = UUID(uuidString: "4652535F-424C-4500-0001-000000000001")!
    public static let configCharUUID = UUID(uuidString: "4652535F-424C-4500-0002-000000000001")!
    public static let nameFilter = "oglo"
    public static let canonicalFingerOrder = ["thumb", "index", "middle", "ring", "pinky"]
    public static let packetHeaderBytes = 6
    public static let channelsPerSample = 5
    public static let bytesPerSample    = channelsPerSample * 2  // 10
    public static let sampleIntervalUs: UInt32 = 10_000          // 100 Hz
}

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
    public let channels: [Channel]

    public func locationForChannel(_ id: Int) -> String? {
        channels.first(where: { $0.id == id })?.loc
    }

    enum CodingKeys: String, CodingKey {
        case device
        case side
        case hwRev = "hw_rev"
        case rateHz = "rate_hz"
        case channels
    }
}
