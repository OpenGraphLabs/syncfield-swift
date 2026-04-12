// Sources/SyncField/Writers/ManifestWriter.swift
import Foundation

public struct Manifest: Codable, Sendable {
    public struct StreamEntry: Codable, Sendable {
        public let streamId: String
        public let filePath: String
        public let frameCount: Int
        public let kind: String           // "video" | "sensor"
        public let capabilities: StreamCapabilities

        public init(streamId: String, filePath: String, frameCount: Int,
                    kind: String, capabilities: StreamCapabilities) {
            self.streamId = streamId; self.filePath = filePath
            self.frameCount = frameCount; self.kind = kind
            self.capabilities = capabilities
        }

        enum CodingKeys: String, CodingKey {
            case streamId     = "stream_id"
            case filePath     = "file_path"
            case frameCount   = "frame_count"
            case kind
            case capabilities
        }
    }

    public let sdkVersion: String
    public let hostId: String
    public let role: String                // v0.2: always "single"
    public let streams: [StreamEntry]

    public init(sdkVersion: String, hostId: String, role: String, streams: [StreamEntry]) {
        self.sdkVersion = sdkVersion; self.hostId = hostId
        self.role = role; self.streams = streams
    }

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case hostId     = "host_id"
        case role, streams
    }
}

public enum ManifestWriter {
    public static func write(_ manifest: Manifest, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: url, options: [.atomic])
    }
}
