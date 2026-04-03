import Foundation

// MARK: - Errors

public enum SyncFieldError: LocalizedError {
    case sessionAlreadyStarted
    case sessionNotStarted
    case writerNotOpen(String)

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyStarted:
            return "Session already started"
        case .sessionNotStarted:
            return "Session not started — call start() first"
        case .writerNotOpen(let id):
            return "Writer for '\(id)' is not open"
        }
    }
}

// MARK: - SyncSession

/// Capture timestamps for multi-stream synchronization.
///
/// Usage:
/// ```swift
/// let session = SyncSession(hostId: "iphone_01", outputDir: outputURL)
/// try session.start()
///
/// // In your capture callback — call stamp() immediately AFTER each frame
/// let frame = camera.read()
/// try session.stamp("cam_ego", frameNumber: i)
///
/// let counts = try session.stop()
/// ```
///
/// The session is **thread-safe**: `stamp()` / `record()` can be called from
/// multiple threads concurrently (e.g. one thread per device).
public final class SyncSession {

    public let hostId: String
    public let outputDir: URL
    public private(set) var syncPoint: SyncPoint?

    private let lock = NSLock()
    private var writers: [String: StreamWriter] = [:]
    private var sensorWriters: [String: SensorWriter] = [:]
    private var links: [String: String] = [:]
    private var recordedStreams: Set<String> = []
    private var started = false

    public init(hostId: String, outputDir: URL) {
        self.hostId = hostId
        self.outputDir = outputDir
    }

    /// Convenience initializer accepting a file path string.
    public convenience init(hostId: String, outputDir: String) {
        self.init(hostId: hostId, outputDir: URL(fileURLWithPath: outputDir))
    }

    // MARK: - Lifecycle

    /// Begin a recording session.
    ///
    /// Captures a `SyncPoint` and prepares the output directory.
    /// Must be called before `stamp()`. Each `SyncSession` instance
    /// supports multiple start/stop cycles.
    @discardableResult
    public func start() throws -> SyncPoint {
        lock.lock()
        defer { lock.unlock() }

        if started { throw SyncFieldError.sessionAlreadyStarted }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let sp = SyncPoint.createNow(hostId: hostId)
        syncPoint = sp
        writers.removeAll()
        sensorWriters.removeAll()
        links.removeAll()
        recordedStreams.removeAll()
        started = true
        return sp
    }

    /// End the recording session.
    ///
    /// Closes all writers and writes `sync_point.json` and `manifest.json`.
    ///
    /// Returns a mapping of `{stream_id: frame_count}` for all recorded streams.
    @discardableResult
    public func stop() throws -> [String: Int] {
        lock.lock()

        if !started {
            lock.unlock()
            throw SyncFieldError.sessionNotStarted
        }

        // Snapshot state under lock, then mark stopped so no new writes arrive.
        started = false
        let writersCopy = writers
        let sensorWritersCopy = sensorWriters
        let linksCopy = links
        let recordedStreamsCopy = recordedStreams
        let sp = syncPoint

        lock.unlock()

        // Close writers outside lock — safe because started=false prevents new writes.
        var counts: [String: Int] = [:]
        for (streamId, writer) in writersCopy {
            counts[streamId] = writer.count
            try writer.close()
        }
        for (_, writer) in sensorWritersCopy {
            try writer.close()
        }

        if let sp {
            try writeSyncPoint(sp, outputDir: outputDir)
        }

        // Build manifest
        var streams: [String: [String: Any]] = [:]
        let allIds = Set(writersCopy.keys)
            .union(linksCopy.keys)
            .union(recordedStreamsCopy)
            .sorted()

        for streamId in allIds {
            var entry: [String: Any] = [:]

            if recordedStreamsCopy.contains(streamId) {
                entry["type"] = "sensor"
                entry["sensor_path"] = "\(streamId).jsonl"
            } else {
                entry["type"] = "video"
            }

            if let writer = writersCopy[streamId] {
                entry["timestamps_path"] = "\(streamId).timestamps.jsonl"
                entry["frame_count"] = writer.count
            }

            if let path = linksCopy[streamId] {
                entry["path"] = path
            }

            streams[streamId] = entry
        }

        try writeManifest(hostId: hostId, streams: streams, outputDir: outputDir)

        return counts
    }

    // MARK: - Recording

    /// Record a timestamp for one data packet.
    ///
    /// Call this **immediately after** your I/O read completes — before any
    /// processing — to minimise jitter.
    ///
    /// - Parameters:
    ///   - streamId: Identifier for the data stream (e.g. `"cam_left"`).
    ///   - frameNumber: Sequential index (0-based) within this stream.
    ///   - uncertaintyNs: Timing uncertainty estimate (default 5 ms).
    ///   - captureNs: Pre-captured monotonic nanosecond value. If `nil`,
    ///     the SDK captures it at call time.
    /// - Returns: The monotonic nanosecond value used for this timestamp.
    @discardableResult
    public func stamp(
        _ streamId: String,
        frameNumber: Int,
        uncertaintyNs: UInt64 = 5_000_000,
        captureNs: UInt64? = nil
    ) throws -> UInt64 {
        // Capture timestamp BEFORE acquiring lock to minimise jitter.
        let ns = captureNs ?? MonotonicClock.now()

        lock.lock()
        defer { lock.unlock() }

        guard started else { throw SyncFieldError.sessionNotStarted }

        let ts = FrameTimestamp(
            frameNumber: frameNumber,
            captureNs: ns,
            clockSource: "host_monotonic",
            clockDomain: hostId,
            uncertaintyNs: uncertaintyNs
        )

        let writer: StreamWriter
        if let existing = writers[streamId] {
            writer = existing
        } else {
            writer = StreamWriter(streamId: streamId, outputDir: outputDir)
            try writer.open()
            writers[streamId] = writer
        }
        try writer.write(ts)

        return ns
    }

    /// Record a sensor sample with timestamp and channel data.
    ///
    /// Captures a monotonic timestamp, then writes to both
    /// `{stream_id}.timestamps.jsonl` and `{stream_id}.jsonl`.
    ///
    /// - Parameters:
    ///   - streamId: Identifier for the sensor stream (e.g. `"imu"`).
    ///   - frameNumber: Sequential index (0-based) within this stream.
    ///   - channels: Sensor data as `{name: value}` pairs. Values can be
    ///     numbers, arrays, or nested dicts.
    ///   - uncertaintyNs: Timing uncertainty estimate (default 5 ms).
    ///   - captureNs: Pre-captured monotonic nanosecond value. If `nil`,
    ///     the SDK captures it at call time.
    /// - Returns: The monotonic nanosecond value used for this timestamp.
    @discardableResult
    public func record(
        _ streamId: String,
        frameNumber: Int,
        channels: [String: ChannelValue],
        uncertaintyNs: UInt64 = 5_000_000,
        captureNs: UInt64? = nil
    ) throws -> UInt64 {
        // Capture timestamp BEFORE acquiring lock to minimise jitter.
        let ns = captureNs ?? MonotonicClock.now()

        lock.lock()
        defer { lock.unlock() }

        guard started else { throw SyncFieldError.sessionNotStarted }

        let ts = FrameTimestamp(
            frameNumber: frameNumber,
            captureNs: ns,
            clockSource: "host_monotonic",
            clockDomain: hostId,
            uncertaintyNs: uncertaintyNs
        )
        let sample = SensorSample(
            frameNumber: frameNumber,
            captureNs: ns,
            channels: channels,
            clockSource: "host_monotonic",
            clockDomain: hostId,
            uncertaintyNs: uncertaintyNs
        )

        // Timestamp writer
        let tsWriter: StreamWriter
        if let existing = writers[streamId] {
            tsWriter = existing
        } else {
            tsWriter = StreamWriter(streamId: streamId, outputDir: outputDir)
            try tsWriter.open()
            writers[streamId] = tsWriter
        }
        try tsWriter.write(ts)

        // Sensor data writer
        let senWriter: SensorWriter
        if let existing = sensorWriters[streamId] {
            senWriter = existing
        } else {
            senWriter = SensorWriter(streamId: streamId, outputDir: outputDir)
            try senWriter.open()
            sensorWriters[streamId] = senWriter
        }
        try senWriter.write(sample)

        recordedStreams.insert(streamId)

        return ns
    }

    /// Associate an external file path with a stream.
    ///
    /// Use this for files produced outside the SDK (e.g. video files).
    /// The association is recorded in `manifest.json` when `stop()` is called.
    public func link(_ streamId: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        links[streamId] = path
    }
}
