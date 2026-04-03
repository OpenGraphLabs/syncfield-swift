import Foundation

/// SDK version string embedded in output files.
public let syncFieldVersion = "0.1.0"

/// Sensor channel value type.
///
/// Leaf values must be numeric (`Double` or `Int`).
/// Structure can be nested dicts or arrays.
///
/// Examples:
/// - flat:   `["accel_x": 0.12, "accel_y": -9.8]`
/// - nested: `["joints": ["wrist": [0.1, 0.2, 0.3]]]`
public typealias ChannelValue = Any

// MARK: - SyncPoint

/// Reference time captured at recording start.
///
/// Anchors the monotonic clock to wall-clock time for cross-host alignment.
public struct SyncPoint {
    public let monotonicNs: UInt64
    public let wallClockNs: UInt64
    public let hostId: String
    public let timestampMs: UInt64
    public let isoDatetime: String

    /// Capture a sync point at the current moment.
    public static func createNow(hostId: String) -> SyncPoint {
        let mono = MonotonicClock.now()
        let wall = MonotonicClock.wallClockNs()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return SyncPoint(
            monotonicNs: mono,
            wallClockNs: wall,
            hostId: hostId,
            timestampMs: wall / 1_000_000,
            isoDatetime: formatter.string(from: Date())
        )
    }

    public func toDict() -> [String: Any] {
        [
            "monotonic_ns": monotonicNs,
            "wall_clock_ns": wallClockNs,
            "host_id": hostId,
            "timestamp_ms": timestampMs,
            "iso_datetime": isoDatetime,
        ]
    }
}

// MARK: - FrameTimestamp

/// Single timestamp for one data packet (camera frame or sensor sample).
///
/// Compatible with the SyncField recorder's `frame_timestamps.jsonl` schema.
public struct FrameTimestamp {
    public let frameNumber: Int
    public let captureNs: UInt64
    public let clockSource: String
    public let clockDomain: String
    public let uncertaintyNs: UInt64

    public func toDict() -> [String: Any] {
        [
            "frame_number": frameNumber,
            "capture_ns": captureNs,
            "clock_source": clockSource,
            "clock_domain": clockDomain,
            "uncertainty_ns": uncertaintyNs,
        ]
    }
}

// MARK: - SensorSample

/// Sensor data sample with embedded timestamp.
///
/// Combines timestamp and channel data in one record, written to `{stream_id}.jsonl`.
public struct SensorSample {
    public let frameNumber: Int
    public let captureNs: UInt64
    public let channels: [String: ChannelValue]
    public let clockSource: String
    public let clockDomain: String
    public let uncertaintyNs: UInt64

    public func toDict() -> [String: Any] {
        [
            "frame_number": frameNumber,
            "capture_ns": captureNs,
            "clock_source": clockSource,
            "clock_domain": clockDomain,
            "uncertainty_ns": uncertaintyNs,
            "channels": channels,
        ]
    }
}
