// Sources/SyncField/Audio/ChirpPlayer.swift
import Foundation

/// Abstraction over tone emission. The default iOS implementation is
/// `AVAudioEngineChirpPlayer`; use `SilentChirpPlayer` for tests or
/// when running on a host without audio output.
public protocol ChirpPlayer: Sendable {
    var isSilent: Bool { get }
    func play(_ spec: ChirpSpec) async -> ChirpEmission
}

public struct SilentChirpPlayer: ChirpPlayer {
    public init() {}
    public var isSilent: Bool { true }
    public func play(_ spec: ChirpSpec) async -> ChirpEmission {
        let now = currentMonotonicNs()
        return ChirpEmission(softwareNs: now, hardwareNs: nil, source: .silent)
    }
}

@inline(__always)
func currentMonotonicNs() -> UInt64 {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom)
}
