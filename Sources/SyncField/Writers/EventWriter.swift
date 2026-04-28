// Sources/SyncField/Writers/EventWriter.swift
import Foundation

/// Opaque token returned by ``EventWriter/appendIntervalStart(...)`` and
/// passed back to ``EventWriter/closeInterval(handle:endMonotonicNs:endFrame:)``
/// when the interval ends. Identifies one in-flight interval inside the writer.
public struct EventHandle: Sendable, Equatable {
    let id: UInt64
}

/// Append-only JSON Lines writer for per-episode interval and point events.
///
/// One record per line; lines are independently parseable so downstream
/// pipelines can `grep` or `jq -c` without worrying about multi-line records.
/// Open intervals at ``finalize(stopMonotonicNs:stopFrame:)`` are auto-closed
/// with ``end_monotonic_ns`` set to the stop time and a
/// ``payload._truncated_at_stop = true`` flag added.
public actor EventWriter {
    private let fileURL: URL
    private let streamId: String
    private var fileHandle: FileHandle?
    private var nextId: UInt64 = 1
    private var openIntervals: [UInt64: OpenInterval] = [:]
    private var pendingLines: [String] = []

    private struct OpenInterval {
        let kind: String
        let startMonotonicNs: UInt64
        let startFrame: Int
        let payload: [String: Any]
    }

    public init(fileURL: URL, streamId: String = "cam_ego") {
        self.fileURL = fileURL
        self.streamId = streamId
    }

    /// Open a new interval; returns a handle to be passed to ``closeInterval``.
    /// The record is buffered and not flushed until the interval closes.
    public func appendIntervalStart(kind: String,
                                    startMonotonicNs: UInt64,
                                    startFrame: Int,
                                    payload: [String: Any]) async throws -> EventHandle {
        let id = nextId
        nextId += 1
        openIntervals[id] = OpenInterval(
            kind: kind,
            startMonotonicNs: startMonotonicNs,
            startFrame: startFrame,
            payload: payload
        )
        return EventHandle(id: id)
    }

    /// Close an interval previously opened with ``appendIntervalStart``.
    /// Writes the complete record (including ``frame_start`` and ``frame_end``).
    public func closeInterval(handle: EventHandle,
                              endMonotonicNs: UInt64,
                              endFrame: Int) async throws {
        guard let open = openIntervals.removeValue(forKey: handle.id) else { return }
        try writeRecord(
            kind: open.kind,
            startMonotonicNs: open.startMonotonicNs,
            endMonotonicNs: endMonotonicNs,
            payload: open.payload,
            extraPayload: ["frame_start": open.startFrame, "frame_end": endFrame]
        )
    }

    /// Write a point event (``start_monotonic_ns == end_monotonic_ns``).
    public func appendPoint(kind: String,
                            monotonicNs: UInt64,
                            payload: [String: Any]) async throws {
        try writeRecord(
            kind: kind,
            startMonotonicNs: monotonicNs,
            endMonotonicNs: monotonicNs,
            payload: payload,
            extraPayload: [:]
        )
    }

    /// Close any still-open intervals at ``stopMonotonicNs``, flush, and
    /// release the file handle. Truncated intervals get
    /// ``payload._truncated_at_stop = true`` so downstream code can spot them.
    public func finalize(stopMonotonicNs: UInt64, stopFrame: Int) async throws {
        let stillOpen = openIntervals
        openIntervals.removeAll()
        for (_, open) in stillOpen {
            try writeRecord(
                kind: open.kind,
                startMonotonicNs: open.startMonotonicNs,
                endMonotonicNs: stopMonotonicNs,
                payload: open.payload,
                extraPayload: [
                    "frame_start": open.startFrame,
                    "frame_end": stopFrame,
                    "_truncated_at_stop": true,
                ]
            )
        }
        await flushImpl()
        try? fileHandle?.close()
        fileHandle = nil
    }

    /// Flush any buffered lines to disk. Tests use this to read records
    /// without finalizing the writer.
    public func flush() async {
        await flushImpl()
    }

    // MARK: private

    private func flushImpl() async {
        guard !pendingLines.isEmpty else { return }
        if fileHandle == nil {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let h = fileHandle else { return }
        for line in pendingLines {
            if let data = (line + "\n").data(using: .utf8) {
                try? h.write(contentsOf: data)
            }
        }
        try? h.synchronize()
        pendingLines.removeAll()
    }

    private func writeRecord(kind: String,
                             startMonotonicNs: UInt64,
                             endMonotonicNs: UInt64,
                             payload: [String: Any],
                             extraPayload: [String: Any]) throws {
        var combined = payload
        for (k, v) in extraPayload {
            combined[k] = v
        }
        let record: [String: Any] = [
            "kind": kind,
            "start_monotonic_ns": startMonotonicNs,
            "end_monotonic_ns": endMonotonicNs,
            "stream_id": streamId,
            "payload": combined,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "EventWriter", code: 1)
        }
        pendingLines.append(line)
    }
}
