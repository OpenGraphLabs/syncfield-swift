// Sources/SyncField/Writers/ManifestWriter.swift
import Foundation

public struct Manifest: Codable, Sendable {
    public struct StreamEntry: Codable, Sendable {
        public let streamId: String
        public let filePath: String
        public let frameCount: Int
        public let kind: String           // "video" | "sensor"
        public let capabilities: StreamCapabilities
        /// Groups entries produced by the same physical stream (e.g. a
        /// stereo camera stream emitting `cam_ego` + `cam_ego_wide` from one
        /// connection). Omitted from the JSON when nil so single-entry
        /// streams stay byte-compatible with existing manifests.
        public let syncGroupId: String?

        public init(streamId: String, filePath: String, frameCount: Int,
                    kind: String, capabilities: StreamCapabilities,
                    syncGroupId: String? = nil) {
            self.streamId = streamId; self.filePath = filePath
            self.frameCount = frameCount; self.kind = kind
            self.capabilities = capabilities
            self.syncGroupId = syncGroupId
        }

        enum CodingKeys: String, CodingKey {
            case streamId     = "stream_id"
            case filePath     = "file_path"
            case frameCount   = "frame_count"
            case kind
            case capabilities
            case syncGroupId  = "sync_group_id"
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
