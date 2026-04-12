// Sources/SyncField/Writers/SessionLogWriter.swift
import Foundation

/// Append-only session log. Each call fsyncs before returning so entries
/// survive a crash. One JSON object per line.
public actor SessionLogWriter {
    private let handle: FileHandle
    private let isoFormatter: ISO8601DateFormatter

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func append(kind: String, detail: String) throws {
        let entry: [String: Any] = [
            "ts":     isoFormatter.string(from: Date()),
            "kind":   kind,
            "detail": detail,
        ]
        var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()  // fsync on every entry
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
