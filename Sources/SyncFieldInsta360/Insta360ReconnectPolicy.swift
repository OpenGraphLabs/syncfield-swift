import Foundation

/// Backoff schedule + persistent classifier for `Insta360CameraSupervisor`'s
/// auto-reconnect path. Stateless / pure — easy to unit test.
///
/// Schedule mirrors the plan's "Backoff" section: 0.5 → 1 → 2 → 4 → 8 →
/// 15 → 30 → 60 → 60 → 60 s. After exhausting the ramp the supervisor stays
/// on 60 s indefinitely while the app is foregrounded.
public struct Insta360ReconnectPolicy: Sendable, Equatable {
    public let backoffScheduleSeconds: [TimeInterval]

    /// Maximum number of scheduled retries before the supervisor classifies
    /// the failure as persistent. `Int.max` means "retry forever while
    /// foreground". Persistent classifier (`shouldClassifyAsLost`) can still
    /// short-circuit before this cap.
    public let maxAttempts: Int

    public init(
        backoffScheduleSeconds: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30, 60, 60, 60],
        maxAttempts: Int = .max
    ) {
        precondition(!backoffScheduleSeconds.isEmpty)
        self.backoffScheduleSeconds = backoffScheduleSeconds
        self.maxAttempts = maxAttempts
    }

    /// 1-based attempt. Beyond the schedule length, returns the last value
    /// (the steady-state cadence).
    public func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return backoffScheduleSeconds[0] }
        if attempt - 1 < backoffScheduleSeconds.count {
            return backoffScheduleSeconds[attempt - 1]
        }
        return backoffScheduleSeconds.last!
    }

    /// Classify a disconnect/reconnect failure as persistent based on the
    /// supervisor's accumulated signals. When `true`, the supervisor
    /// transitions to `.lost` immediately rather than continuing the ramp.
    ///
    /// Heuristics:
    /// 1. `consecutiveScanWindowsWithoutAdvert` ≥ config threshold,
    /// 2. error description matches a hard CoreBluetooth class (peripheral
    ///    powered off / out of range / explicit user disconnect),
    /// 3. last advertisement seen longer ago than the persistent threshold.
    public static func shouldClassifyAsLost(
        consecutiveScanWindowsWithoutAdvert: Int,
        lastErrorDescription: String?,
        msSinceLastAdvertisement: UInt64?,
        config: Insta360CoordinatorConfig = .shared
    ) -> Bool {
        if consecutiveScanWindowsWithoutAdvert >= config.persistentScanWindowCount {
            return true
        }
        if let err = lastErrorDescription?.lowercased() {
            // String matches cover both Swift enum stringification
            // (`peripheraldisconnected`) and the human-readable
            // `String(describing:)` of an `NSError` from
            // `CBErrorDomain` (codes 6 + 7 typically surface as the
            // descriptions below). Either form means the peripheral
            // is gone — no point burning more backoff cycles.
            let persistentMarkers = [
                "powered off",
                "out of range",
                "user disconnect",
                "peripheraldisconnected",
                // CBErrorDomain Code=7 — peripheral disconnected from us
                "the specified device has disconnected",
                // CBErrorDomain Code=6 — connection timed out (when the
                // remote side is no longer responding, repeated drops)
                "the connection has timed out unexpectedly",
            ]
            if persistentMarkers.contains(where: err.contains) { return true }
        }
        if let ms = msSinceLastAdvertisement {
            let thresholdMs = UInt64(config.persistentLastSeenThresholdSeconds * 1_000)
            if ms > thresholdMs { return true }
        }
        return false
    }
}
