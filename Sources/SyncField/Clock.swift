import Darwin
import Foundation

enum MonotonicClock {

    /// Current monotonic time in nanoseconds (equivalent to Python's `time.monotonic_ns()`).
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    /// Current wall-clock time in nanoseconds since Unix epoch (equivalent to Python's `time.time_ns()`).
    static func wallClockNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }
}
