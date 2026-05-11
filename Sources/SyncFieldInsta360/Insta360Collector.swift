import Foundation
import SyncField

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK
#endif

/// Standalone entry point for **deferred** Insta360 wrist-camera downloads.
///
/// Use this when the recording loop calls
/// ``SessionOrchestrator/finishRecording()`` instead of `ingest()` — the
/// episode directory is left with `<streamId>.pending.json` sidecars and the
/// actual mp4 is still on each camera's SD. Later, when your UI is ready
/// (an episode-detail "Download" button, or a batch "Collect all" page),
/// invoke:
///
/// - ``collectEpisode(_:progress:)`` — process one episode directory.
/// - ``collectAll(root:progress:)`` — recursively process every episode
///   under a recordings root, grouping work by camera UUID so each
///   camera's AP is joined only once.
///
/// Both methods write each successful mp4 alongside an
/// `<streamId>.anchor.json` and delete the matching `.pending.json`.
/// Independent of any active `SessionOrchestrator` — safe to call long
/// after `disconnect()`.
public actor Insta360Collector {
    public static let shared = Insta360Collector()
    private init() {}

    /// Per-file progress event. `fraction` is 0.0 – 1.0.
    public struct Progress: Sendable {
        public let episodeDir: URL
        public let streamId: String
        public let bleUuid: String
        public let fraction: Double

        public init(episodeDir: URL, streamId: String,
                    bleUuid: String, fraction: Double) {
            self.episodeDir = episodeDir
            self.streamId = streamId
            self.bleUuid = bleUuid
            self.fraction = fraction
        }
    }

    /// Per-file outcome. `error == nil` ⇔ `success == true`.
    public struct Result: Sendable {
        public let episodeDir: URL
        public let streamId: String
        public let bleUuid: String
        public let filePath: URL?
        public let error: Error?

        public var success: Bool { error == nil }

        public init(episodeDir: URL, streamId: String, bleUuid: String,
                    filePath: URL?, error: Error?) {
            self.episodeDir = episodeDir
            self.streamId = streamId
            self.bleUuid = bleUuid
            self.filePath = filePath
            self.error = error
        }
    }

    /// Collect every pending file inside one episode directory.
    ///
    /// Returns `[]` when no `.pending.json` files exist (idempotent: a
    /// previously-collected episode is a no-op).
    public func collectEpisode(
        _ episodeDir: URL,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [Result] {
        let pendings = try Insta360PendingSidecar.scan(episodeDir)
        guard !pendings.isEmpty else { return [] }
        let items = pendings.map {
            Insta360PendingSidecar.WithDir(episodeDir: episodeDir, sidecar: $0)
        }
        return try await runCollect(items: items, progress: progress)
    }

    /// Collect every pending file under `root` (recursive). Files belonging
    /// to the same physical camera are downloaded in one AP join across all
    /// episodes, typically 3 to 5 times faster than running `collectEpisode`
    /// per episode when many episodes share cameras.
    public func collectAll(
        root: URL,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [Result] {
        let items = Insta360PendingSidecar.scanRecursive(root: root)
        guard !items.isEmpty else { return [] }
        return try await runCollect(items: items, progress: progress)
    }

    /// Collect pending files for an explicit set of episode directories.
    ///
    /// Unlike ``collectAll(root:progress:)`` this does not walk unrelated
    /// recordings under the same root. It still groups by camera UUID, so a
    /// selected batch upload only joins each physical camera AP once.
    public func collectEpisodes(
        _ episodeDirs: [URL],
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [Result] {
        let items = try Self.itemsForEpisodeDirs(episodeDirs)
        guard !items.isEmpty else { return [] }
        return try await runCollect(items: items, progress: progress)
    }

    // MARK: - Pure helper (unit-tested)

    /// Group pending items by camera UUID, preserving deterministic order
    /// (sort UUID keys alphabetically and within a UUID sort by episode
    /// path then streamId). The collector iterates this output to drive
    /// one AP join per camera.
    public static func groupByCamera(
        _ items: [Insta360PendingSidecar.WithDir]
    ) -> [(uuid: String, items: [Insta360PendingSidecar.WithDir])] {
        let grouped = Dictionary(grouping: items, by: { $0.sidecar.bleUuid })
        return grouped.keys.sorted().map { uuid in
            let bucket = grouped[uuid]!.sorted { a, b in
                if a.episodeDir.path != b.episodeDir.path {
                    return a.episodeDir.path < b.episodeDir.path
                }
                return a.sidecar.streamId < b.sidecar.streamId
            }
            return (uuid: uuid, items: bucket)
        }
    }

    public static func itemsForEpisodeDirs(
        _ episodeDirs: [URL]
    ) throws -> [Insta360PendingSidecar.WithDir] {
        var items: [Insta360PendingSidecar.WithDir] = []
        for dir in episodeDirs {
            for sidecar in try Insta360PendingSidecar.scan(dir) {
                let mp4 = dir.appendingPathComponent("\(sidecar.streamId).mp4")
                if FileManager.default.fileExists(atPath: mp4.path) {
                    continue
                }
                items.append(Insta360PendingSidecar.WithDir(
                    episodeDir: dir,
                    sidecar: sidecar))
            }
        }
        return items
    }

    // MARK: - Private orchestration

    #if canImport(INSCameraServiceSDK)
    /// 15-second BLE scan budget — long enough for a sleeping Go-family
    /// camera to wake and advertise after the user picks it up, short
    /// enough to fail visibly when a camera is genuinely offline.
    private static let discoveryTimeoutSeconds: UInt64 = 15

    private func runCollect(
        items: [Insta360PendingSidecar.WithDir],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [Result] {
        let groups = Self.groupByCamera(items)
        let neededUUIDs = Set(groups.map(\.uuid))

        // Ensure every needed camera is BLE-discovered (and therefore
        // pairable). UUIDs already paired in this process are skipped.
        let alreadyPaired = await Insta360Scanner.shared.pairedUUIDs()
        let missing = neededUUIDs.subtracting(alreadyPaired)
        if !missing.isEmpty {
            try await discoverUUIDs(missing,
                                     timeoutSeconds: Self.discoveryTimeoutSeconds)
        }

        var results: [Result] = []

        // iOS can only be on one WiFi AP at a time — process cameras sequentially.
        for (uuid, group) in groups {
            do {
                try await Insta360Scanner.shared.pair(uuid: uuid)
                let ble = try await Insta360Scanner.shared.controller(forUUID: uuid)
                let creds = try await ble.wifiCredentials()

                let batchItems = group.map { item in
                    Insta360WiFiDownloader.BatchItem(
                        episodeDir: item.episodeDir,
                        streamId: item.sidecar.streamId,
                        remoteFileURI: item.sidecar.cameraFileURI,
                        destination: item.episodeDir.appendingPathComponent(
                            "\(item.sidecar.streamId).mp4"),
                        bleAckMonotonicNs: item.sidecar.bleAckMonotonicNs)
                }

                let downloader = Insta360WiFiDownloader()
                let batchResults = await downloader.downloadBatch(
                    ssid: creds.ssid,
                    passphrase: creds.passphrase,
                    items: batchItems,
                    onItemStart: { _ in },
                    progress: { batchItem, fraction in
                        progress(Progress(
                            episodeDir: batchItem.episodeDir,
                            streamId: batchItem.streamId,
                            bleUuid: uuid,
                            fraction: fraction))
                    })

                for br in batchResults {
                    guard let owner = group.first(where: {
                        $0.sidecar.streamId == br.item.streamId &&
                        $0.episodeDir == br.item.episodeDir
                    }) else { continue }

                    if br.success {
                        try? Insta360PendingSidecar.delete(
                            at: owner.episodeDir, streamId: owner.sidecar.streamId)
                        results.append(Result(
                            episodeDir: owner.episodeDir,
                            streamId: owner.sidecar.streamId,
                            bleUuid: uuid,
                            filePath: br.item.destination,
                            error: nil))
                    } else {
                        results.append(Result(
                            episodeDir: owner.episodeDir,
                            streamId: owner.sidecar.streamId,
                            bleUuid: uuid,
                            filePath: nil,
                            error: Insta360Error.downloadFailed(
                                br.error ?? "unknown")))
                    }
                }
            } catch {
                // Camera-level failure (pair / wifiCredentials threw): mark
                // every queued item under this UUID as failed and keep
                // going so the next camera still gets a chance.
                for item in group {
                    results.append(Result(
                        episodeDir: item.episodeDir,
                        streamId: item.sidecar.streamId,
                        bleUuid: uuid,
                        filePath: nil,
                        error: error))
                }
            }
        }

        // Best-effort final camera-hotspot config cleanup. Do not sweep all
        // app-managed SSIDs here: upload Wi-Fi configs may also have been
        // installed through NEHotspotConfiguration and must survive collect.
        let finalDownloader = Insta360WiFiDownloader()
        await finalDownloader.finalizeWiFiRestore()
        await finalDownloader.removeCameraHotspotConfigurations()

        return results
    }

    /// Run a BLE scan until every UUID in `needed` is observed (and thus
    /// cached for `Insta360Scanner.pair(uuid:)`) or `timeoutSeconds`
    /// elapses. Stops the scan in either case. Returns silently — pair
    /// errors at the call site surface "deviceNotDiscovered" for any
    /// camera the scan never saw, which carries the right diagnostic.
    private func discoverUUIDs(_ needed: Set<String>,
                                timeoutSeconds: UInt64) async throws {
        await Insta360Scanner.shared.stopScan()
        let stream = try await Insta360Scanner.shared.scan()

        let timeout = Task { [needed] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            await Insta360Scanner.shared.stopScan()
            _ = needed   // silence captured-but-unused under release builds
        }

        var seen: Set<String> = []
        for await camera in stream {
            seen.insert(camera.uuid)
            if needed.isSubset(of: seen) {
                await Insta360Scanner.shared.stopScan()
                break
            }
        }
        timeout.cancel()
    }
    #else
    private func runCollect(
        items _: [Insta360PendingSidecar.WithDir],
        progress _: @escaping @Sendable (Progress) -> Void
    ) async throws -> [Result] {
        throw Insta360Error.frameworkNotLinked
    }
    #endif
}
