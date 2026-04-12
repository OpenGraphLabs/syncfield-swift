// Sources/SyncField/StreamCapabilities.swift
import Foundation

public struct StreamCapabilities: Codable, Equatable, Sendable {
    public var requiresIngest: Bool
    public var producesFile: Bool
    public var supportsPreciseTimestamps: Bool

    public init(requiresIngest: Bool = false,
                producesFile: Bool = true,
                supportsPreciseTimestamps: Bool = true) {
        self.requiresIngest = requiresIngest
        self.producesFile   = producesFile
        self.supportsPreciseTimestamps = supportsPreciseTimestamps
    }

    enum CodingKeys: String, CodingKey {
        case requiresIngest = "requires_ingest"
        case producesFile   = "produces_file"
        case supportsPreciseTimestamps = "supports_precise_timestamps"
    }
}
