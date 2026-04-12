// Sources/SyncField/Writers/StreamWriter.swift
import Foundation

/// Writes one JSON line per video frame timestamp.
/// Each call to `append` is atomic w.r.t. the writer actor.
public actor StreamWriter {
    private let handle: FileHandle
    private var frameCount: Int = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public var count: Int { frameCount }

    public func append(frame: Int, monotonicNs: UInt64, uncertaintyNs: UInt64) throws {
        let obj: [String: Any] = [
            "frame": frame,
            "timestamp_ns": monotonicNs,
            "uncertainty_ns": uncertaintyNs,
        ]
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)  // '\n'
        try handle.write(contentsOf: data)
        frameCount += 1
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
