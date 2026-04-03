import Foundation

// MARK: - JSON helpers

/// Serialize a dictionary to a compact JSON line WITH trailing newline.
/// Matches Python's `json.dumps(data, separators=(",", ":")) + "\n"`.
/// Returns a single Data for atomic write.
func compactJSONLine(_ dict: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    data.append(0x0A)  // newline
    return data
}

/// Serialize a dictionary to pretty-printed JSON with a trailing newline.
/// Matches Python's `json.dump(data, f, indent=2)` + `f.write("\n")`.
func prettyJSON(_ dict: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
    )
    // Fix Apple's `" : "` spacing to match Python's `": "`.
    if let str = String(data: data, encoding: .utf8) {
        let fixed = str.replacingOccurrences(of: " : ", with: ": ")
        data = Data(fixed.utf8)
    }
    data.append(0x0A)  // trailing newline
    return data
}

// MARK: - StreamWriter

/// Writes `FrameTimestamp` entries to a per-stream JSONL file.
///
/// Each call to `write(_:)` appends one JSON line and flushes immediately
/// so that timestamps are persisted even if the process crashes mid-recording.
final class StreamWriter {

    let streamId: String
    private let path: URL
    private var handle: FileHandle?
    private(set) var count: Int = 0

    init(streamId: String, outputDir: URL) {
        self.streamId = streamId
        self.path = outputDir.appendingPathComponent("\(streamId).timestamps.jsonl")
    }

    func open() throws {
        FileManager.default.createFile(atPath: path.path, contents: nil)
        handle = try FileHandle(forWritingTo: path)
    }

    func write(_ ts: FrameTimestamp) throws {
        guard let handle else {
            throw SyncFieldError.writerNotOpen(streamId)
        }
        let line = try compactJSONLine(ts.toDict())
        try handle.write(contentsOf: line)
        count += 1
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }
}

// MARK: - SensorWriter

/// Writes `SensorSample` entries to a per-stream JSONL file.
///
/// Output file: `{stream_id}.jsonl`
final class SensorWriter {

    let streamId: String
    private let path: URL
    private var handle: FileHandle?
    private(set) var count: Int = 0

    init(streamId: String, outputDir: URL) {
        self.streamId = streamId
        self.path = outputDir.appendingPathComponent("\(streamId).jsonl")
    }

    func open() throws {
        FileManager.default.createFile(atPath: path.path, contents: nil)
        handle = try FileHandle(forWritingTo: path)
    }

    func write(_ sample: SensorSample) throws {
        guard let handle else {
            throw SyncFieldError.writerNotOpen(streamId)
        }
        let line = try compactJSONLine(sample.toDict())
        try handle.write(contentsOf: line)
        count += 1
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }
}

// MARK: - File writers

/// Write `sync_point.json` to the output directory.
func writeSyncPoint(_ syncPoint: SyncPoint, outputDir: URL) throws {
    let path = outputDir.appendingPathComponent("sync_point.json")
    var dict: [String: Any] = ["sdk_version": syncFieldVersion]
    for (key, value) in syncPoint.toDict() {
        dict[key] = value
    }
    let data = try prettyJSON(dict)
    try data.write(to: path)
}

/// Write `manifest.json` to the output directory.
func writeManifest(hostId: String, streams: [String: [String: Any]], outputDir: URL) throws {
    let manifest: [String: Any] = [
        "sdk_version": syncFieldVersion,
        "host_id": hostId,
        "streams": streams,
    ]
    let path = outputDir.appendingPathComponent("manifest.json")
    let data = try prettyJSON(manifest)
    try data.write(to: path)
}
