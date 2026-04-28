// Sources/SyncField/Writers/SensorWriter.swift
import Foundation

public actor SensorWriter {
    private let handle: FileHandle
    private var frameCount: Int = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public var count: Int { frameCount }

    public func append(frame: Int, monotonicNs: UInt64,
                       channels: [String: Any],
                       deviceTimestampNs: UInt64? = nil) throws {
        var obj: [String: Any] = [
            "frame_number": frame,
            "capture_ns": monotonicNs,
            "channels": channels,
        ]
        if let dts = deviceTimestampNs { obj["device_timestamp_ns"] = dts }

        var data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        frameCount += 1
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
