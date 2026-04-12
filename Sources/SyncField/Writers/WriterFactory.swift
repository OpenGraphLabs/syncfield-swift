// Sources/SyncField/Writers/WriterFactory.swift
import Foundation

/// Injected into `Stream.startRecording` so the stream creates writers
/// rooted at the episode directory, without knowing the directory path.
public struct WriterFactory: Sendable {
    public let episodeDirectory: URL

    public init(episodeDirectory: URL) { self.episodeDirectory = episodeDirectory }

    public func makeStreamWriter(streamId: String) throws -> StreamWriter {
        try StreamWriter(url: episodeDirectory
            .appendingPathComponent("\(streamId).timestamps.jsonl"))
    }

    public func makeSensorWriter(streamId: String) throws -> SensorWriter {
        try SensorWriter(url: episodeDirectory
            .appendingPathComponent("\(streamId).jsonl"))
    }

    public func videoURL(streamId: String, extension ext: String = "mp4") -> URL {
        episodeDirectory.appendingPathComponent("\(streamId).\(ext)")
    }
}
