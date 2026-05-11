import Foundation

/// On-disk record of a wrist-camera recording whose WiFi download has
/// not happened yet. Written at `stopRecording` time (so that the file
/// URI is not lost if `ingest` is skipped or fails), deleted at successful
/// `ingest` or `collectEpisode`. Same directory as the final `.mp4`.
public struct Insta360PendingSidecar: Codable, Sendable {
    public let streamId: String
    public let cameraFileURI: String
    public let bleUuid: String
    public let bleName: String
    public let role: String              // "ego" | "left" | "right"
    public let bleAckMonotonicNs: UInt64
    public let savedAt: String           // ISO8601

    // MARK: - Naming

    public static func filename(forStreamId streamId: String) -> String {
        "\(streamId).pending.json"
    }

    // MARK: - Write

    public static func write(
        to episodeDirectory: URL,
        streamId: String,
        cameraFileURI: String,
        bleUuid: String,
        bleName: String,
        role: String,
        bleAckNs: UInt64
    ) throws {
        let sidecar = Insta360PendingSidecar(
            streamId: streamId,
            cameraFileURI: cameraFileURI,
            bleUuid: bleUuid,
            bleName: bleName,
            role: role,
            bleAckMonotonicNs: bleAckNs,
            savedAt: ISO8601DateFormatter().string(from: Date()))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        let url = episodeDirectory.appendingPathComponent(filename(forStreamId: streamId))
        try FileManager.default.createDirectory(
            at: episodeDirectory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Scan

    public static func scan(_ episodeDirectory: URL) throws -> [Insta360PendingSidecar] {
        let files = try FileManager.default.contentsOfDirectory(
            at: episodeDirectory, includingPropertiesForKeys: nil)
        let pendings = files.filter { $0.lastPathComponent.hasSuffix(".pending.json") }
        let decoder = JSONDecoder()
        return try pendings.map { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(Insta360PendingSidecar.self, from: data)
        }
    }

    /// A sidecar paired with the episode directory it lives in. Used by the
    /// batch-collect flow that walks the entire recordings root to find every
    /// pending file across every episode.
    public struct WithDir: Sendable {
        public let episodeDir: URL
        public let sidecar: Insta360PendingSidecar
    }

    /// Recursively scan every `*.pending.json` under `root`. Used by the
    /// batch-collect flow so a single pass finds pendings across all
    /// `rec_*/ep_*/` episodes at once. Decode failures are logged and
    /// skipped — one malformed sidecar shouldn't break the whole batch.
    public static func scanRecursive(root: URL) -> [WithDir] {
        var results: [WithDir] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }
        let decoder = JSONDecoder()
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".pending.json") else { continue }
            do {
                let data = try Data(contentsOf: url)
                let sidecar = try decoder.decode(Insta360PendingSidecar.self, from: data)
                results.append(WithDir(
                    episodeDir: url.deletingLastPathComponent(),
                    sidecar: sidecar))
            } catch {
                NSLog("[PendingSidecar] Skipping malformed \(url.path): \(error)")
            }
        }
        return results
    }

    // MARK: - Delete

    public static func delete(
        at episodeDirectory: URL, streamId: String
    ) throws {
        let url = episodeDirectory.appendingPathComponent(filename(forStreamId: streamId))
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
