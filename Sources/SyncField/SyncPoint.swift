// Sources/SyncField/SyncPoint.swift
import Foundation

public struct SyncPoint: Codable, Equatable, Sendable {
    public let sdkVersion: String
    public let monotonicNs: UInt64
    public let wallClockNs: UInt64
    public let hostId: String
    public let isoDatetime: String

    // Chirp fields — nil when chirps are disabled
    public var chirpStartNs: UInt64?
    public var chirpStopNs: UInt64?
    public var chirpStartSource: ChirpSource?
    public var chirpStopSource: ChirpSource?
    public var chirpSpec: ChirpSpec?

    public init(sdkVersion: String, monotonicNs: UInt64, wallClockNs: UInt64,
                hostId: String, isoDatetime: String,
                chirpStartNs: UInt64? = nil,
                chirpStopNs: UInt64? = nil,
                chirpStartSource: ChirpSource? = nil,
                chirpStopSource: ChirpSource? = nil,
                chirpSpec: ChirpSpec? = nil) {
        self.sdkVersion  = sdkVersion
        self.monotonicNs = monotonicNs
        self.wallClockNs = wallClockNs
        self.hostId      = hostId
        self.isoDatetime = isoDatetime
        self.chirpStartNs = chirpStartNs
        self.chirpStopNs  = chirpStopNs
        self.chirpStartSource = chirpStartSource
        self.chirpStopSource  = chirpStopSource
        self.chirpSpec = chirpSpec
    }

    enum CodingKeys: String, CodingKey {
        case sdkVersion  = "sdk_version"
        case monotonicNs = "monotonic_ns"
        case wallClockNs = "wall_clock_ns"
        case hostId      = "host_id"
        case isoDatetime = "iso_datetime"
        case chirpStartNs     = "chirp_start_ns"
        case chirpStopNs      = "chirp_stop_ns"
        case chirpStartSource = "chirp_start_source"
        case chirpStopSource  = "chirp_stop_source"
        case chirpSpec        = "chirp_spec"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sdkVersion,  forKey: .sdkVersion)
        try c.encode(monotonicNs, forKey: .monotonicNs)
        try c.encode(wallClockNs, forKey: .wallClockNs)
        try c.encode(hostId,      forKey: .hostId)
        try c.encode(isoDatetime, forKey: .isoDatetime)
        // Chirp fields: only encode if present
        try c.encodeIfPresent(chirpStartNs,     forKey: .chirpStartNs)
        try c.encodeIfPresent(chirpStopNs,      forKey: .chirpStopNs)
        try c.encodeIfPresent(chirpStartSource, forKey: .chirpStartSource)
        try c.encodeIfPresent(chirpStopSource,  forKey: .chirpStopSource)
        try c.encodeIfPresent(chirpSpec,        forKey: .chirpSpec)
    }
}
