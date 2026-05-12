// Sources/SyncField/SessionClock.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Provides the monotonic clock used to stamp every frame in a session,
/// plus a wall-clock anchor captured once at session start.
public final class SessionClock: @unchecked Sendable {
    private let timebase: mach_timebase_info_data_t

    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        self.timebase = tb
    }

    /// Current monotonic clock in nanoseconds. Never goes backwards.
    public func nowMonotonicNs() -> UInt64 {
        machTicksToMonotonicNs(mach_absolute_time())
    }

    /// Convert a CoreMotion / AVFoundation mach-tick timestamp to session ns.
    public func machTicksToMonotonicNs(_ ticks: UInt64) -> UInt64 {
        // ns = ticks * numer / denom
        let num = UInt64(timebase.numer)
        let den = UInt64(timebase.denom)
        return ticks &* num / den
    }

    /// Capture a `SyncPoint` anchoring monotonic to wall clock.
    public func anchor(hostId: String, sdkVersion: String = SyncFieldVersion.current) -> SyncPoint {
        let mono = nowMonotonicNs()
        let wall = UInt64(Date().timeIntervalSince1970 * 1_000_000_000.0)
        let iso  = ISO8601DateFormatter().string(from: Date())
        return SyncPoint(sdkVersion: sdkVersion,
                         monotonicNs: mono, wallClockNs: wall,
                         hostId: hostId, isoDatetime: iso)
    }
}

/// Single source of truth for the SDK version. Embedded into every
/// `sync_point.json` and `manifest.json` written by the orchestrator, and
/// re-exported through `SyncFieldInsta360.version` so optional modules stay
/// in lock-step with the core release.
public enum SyncFieldVersion {
    public static let current = "0.9.0"
}
