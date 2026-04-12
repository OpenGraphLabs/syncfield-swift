// Sources/SyncField/SyncPoint.swift
import Foundation

public struct SyncPoint: Codable, Equatable, Sendable {
    public let sdkVersion: String
    public let monotonicNs: UInt64
    public let wallClockNs: UInt64
    public let hostId: String
    public let isoDatetime: String

    public init(sdkVersion: String, monotonicNs: UInt64, wallClockNs: UInt64,
                hostId: String, isoDatetime: String) {
        self.sdkVersion  = sdkVersion
        self.monotonicNs = monotonicNs
        self.wallClockNs = wallClockNs
        self.hostId      = hostId
        self.isoDatetime = isoDatetime
    }

    enum CodingKeys: String, CodingKey {
        case sdkVersion  = "sdk_version"
        case monotonicNs = "monotonic_ns"
        case wallClockNs = "wall_clock_ns"
        case hostId      = "host_id"
        case isoDatetime = "iso_datetime"
    }
}
