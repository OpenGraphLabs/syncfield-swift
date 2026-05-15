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
    private var activeListFilesTasks: [String: Task<[Insta360FileInfo], Error>] = [:]

    /// Per-file progress event. `fraction` is 0.0 - 1.0 when `phase` is
    /// `downloading`. Non-download phases let clients render the BLE/Wi-Fi
    /// setup work that happens before bytes start moving.
    public struct Progress: Sendable {
        public let episodeDir: URL
        public let streamId: String
        public let bleUuid: String
        public let phase: String
        public let fraction: Double
        public let ssid: String?
        public let cameraLabel: String?

        public init(episodeDir: URL, streamId: String,
                    bleUuid: String, phase: String = "downloading",
                    fraction: Double,
                    ssid: String? = nil,
                    cameraLabel: String? = nil) {
            self.episodeDir = episodeDir
            self.streamId = streamId
            self.bleUuid = bleUuid
            self.phase = phase
            self.fraction = fraction
            self.ssid = ssid
            self.cameraLabel = cameraLabel
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

    struct PrefetchPairingOutcome: Equatable {
        let prefetchedUUIDs: [String]
        let wasCancelled: Bool
    }

    /// Collect every pending file inside one episode directory.
    ///
    /// Returns `[]` when no `.pending.json` files exist (idempotent: a
    /// previously-collected episode is a no-op).
    public func collectEpisode(
        _ episodeDir: URL,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [Result] {
        let items = try Self.itemsForEpisodeDirs([episodeDir])
        guard !items.isEmpty else { return [] }
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

    public func listFiles(
        uuid: String,
        preferredName: String? = nil,
        thumbnailReferenceDate: Date? = nil
    ) async throws -> [Insta360FileInfo] {
        let key = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let active = activeListFilesTasks[key] {
            NSLog("[Insta360Collector] joining active listFiles uuid=\(key)")
            return try await active.value
        }

        let task = Task { [key, preferredName, thumbnailReferenceDate] in
            try await Self.performListFiles(
                uuid: key,
                preferredName: preferredName,
                thumbnailReferenceDate: thumbnailReferenceDate)
        }
        activeListFilesTasks[key] = task
        defer { activeListFilesTasks[key] = nil }
        return try await task.value
    }

    private static func performListFiles(
        uuid: String,
        preferredName: String? = nil,
        thumbnailReferenceDate: Date? = nil
    ) async throws -> [Insta360FileInfo] {
        #if canImport(INSCameraServiceSDK)
        try await Insta360Scanner.shared.pair(
            uuid: uuid,
            preferredName: preferredName)
        defer {
            Task {
                try? await Insta360Scanner.shared.unpair(uuid: uuid)
            }
        }
        let ble = try await Insta360Scanner.shared.controller(forUUID: uuid)
        try? await ble.enableWiFiForDownload()
        let creds = try await ble.wifiCredentials()
        let downloader = Insta360WiFiDownloader()
        return try await downloader.listFiles(
            ssid: creds.ssid,
            passphrase: creds.passphrase,
            thumbnailReferenceDate: thumbnailReferenceDate,
            includeThumbnails: false,
            beforeRestore: { files in
                await enrichMissingThumbnailsWithBLE(
                    files,
                    ble: ble,
                    referenceDate: thumbnailReferenceDate)
            })
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    static func foregroundWaitProgressEvents(
        for group: (uuid: String, items: [Insta360PendingSidecar.WithDir]),
        ssid: String,
        cameraLabel: String?,
        episodeDir: URL? = nil,
        streamId: String? = nil
    ) -> [Progress] {
        if let episodeDir, let streamId {
            return [
                Progress(
                    episodeDir: episodeDir,
                    streamId: streamId,
                    bleUuid: group.uuid,
                    phase: "awaiting_wifi_join",
                    fraction: 0,
                    ssid: ssid,
                    cameraLabel: cameraLabel),
            ]
        }

        return progressEvents(
            for: group,
            phase: "awaiting_wifi_join",
            ssid: ssid,
            cameraLabel: cameraLabel)
    }

    #if canImport(INSCameraServiceSDK)
    private static func enrichMissingThumbnailsWithBLE(
        _ files: [Insta360FileInfo],
        ble: Insta360BLEController,
        referenceDate: Date?,
        limit: Int = 8
    ) async -> [Insta360FileInfo] {
        guard !files.isEmpty else { return files }

        var output = files
        let requestedIndices = thumbnailCandidateIndices(
            in: files,
            referenceDate: referenceDate,
            limit: limit)
        var successCount = 0
        var failureCount = 0
        var consecutiveFailureCount = 0

        for index in requestedIndices {
            if Task.isCancelled { break }
            let file = output[index]
            guard file.thumbnailUri == nil else { continue }

            do {
                let thumbnailUri = try await ble.miniThumbnailURI(for: file.fileUri)
                output[index] = Insta360FileInfo(
                    fileUri: file.fileUri,
                    createdAtIso: file.createdAtIso,
                    durationSec: file.durationSec,
                    sizeBytes: file.sizeBytes,
                    thumbnailUri: thumbnailUri)
                successCount += 1
                consecutiveFailureCount = 0
            } catch {
                failureCount += 1
                consecutiveFailureCount += 1
                if failureCount <= 3 {
                    NSLog("[Insta360Collector] BLE mini thumbnail failed uri=\(file.fileUri): \(error.localizedDescription)")
                }
                if consecutiveFailureCount >= 3 {
                    NSLog("[Insta360Collector] BLE mini thumbnails stopped after \(consecutiveFailureCount) consecutive failures")
                    break
                }
            }
        }

        if successCount > 0 || failureCount > 0 {
            NSLog("[Insta360Collector] BLE mini thumbnails enriched success=\(successCount) failed=\(failureCount) requested=\(requestedIndices.count)")
        }
        return output
    }

    private static func thumbnailCandidateIndices(
        in files: [Insta360FileInfo],
        referenceDate: Date?,
        limit: Int
    ) -> [Int] {
        let capped = min(limit, files.count)
        guard let referenceDate else {
            return Array(0..<capped)
        }

        let iso = ISO8601DateFormatter()
        return files.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = iso.date(from: lhs.element.createdAtIso)
                let rhsDate = iso.date(from: rhs.element.createdAtIso)
                let lhsDelta = lhsDate.map { abs($0.timeIntervalSince(referenceDate)) }
                    ?? Double.greatestFiniteMagnitude
                let rhsDelta = rhsDate.map { abs($0.timeIntervalSince(referenceDate)) }
                    ?? Double.greatestFiniteMagnitude
                if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
                return lhs.offset < rhs.offset
            }
            .prefix(capped)
            .map(\.offset)
    }
    #endif

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

    static func prefetchPairCameras(
        _ groups: [(uuid: String, items: [Insta360PendingSidecar.WithDir])],
        pair: (String, String?) async throws -> Void
    ) async -> PrefetchPairingOutcome {
        var prefetchedUUIDs: [String] = []
        var wasCancelled = false
        for (uuid, group) in groups {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            do {
                try await pair(uuid, group.first?.sidecar.bleName)
                prefetchedUUIDs.append(uuid)
                NSLog("[Insta360Collector] prefetch pair ok uuid=\(uuid)")
            } catch is CancellationError {
                wasCancelled = true
                NSLog("[Insta360Collector] prefetch pair cancelled uuid=\(uuid)")
                break
            } catch {
                NSLog("[Insta360Collector] prefetch pair failed uuid=\(uuid): \(error.localizedDescription); will retry at per-camera step")
            }
        }
        return PrefetchPairingOutcome(
            prefetchedUUIDs: prefetchedUUIDs,
            wasCancelled: wasCancelled)
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

    static func progressEvents(
        for group: (uuid: String, items: [Insta360PendingSidecar.WithDir]),
        phase: String,
        fraction: Double = 0,
        ssid: String? = nil,
        cameraLabel: String? = nil
    ) -> [Progress] {
        group.items.map { item in
            Progress(
                episodeDir: item.episodeDir,
                streamId: item.sidecar.streamId,
                bleUuid: group.uuid,
                phase: phase,
                fraction: fraction,
                ssid: ssid,
                cameraLabel: cameraLabel)
        }
    }

    #if canImport(INSCameraServiceSDK)
    /// 15-second BLE scan budget — long enough for a sleeping Go-family
    /// camera to wake and advertise after the user picks it up, short
    /// enough to fail visibly when a camera is genuinely offline.
    private static let discoveryTimeoutSeconds: UInt64 = 15

    private func runCollect(
        items: [Insta360PendingSidecar.WithDir],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [Result] {
        try Task.checkCancellation()
        let groups = Self.groupByCamera(items)

        func emitGroupPhase(
            _ group: (uuid: String, items: [Insta360PendingSidecar.WithDir]),
            phase: String,
            fraction: Double = 0,
            ssid: String? = nil,
            cameraLabel: String? = nil
        ) {
            for event in Self.progressEvents(
                for: group,
                phase: phase,
                fraction: fraction,
                ssid: ssid,
                cameraLabel: cameraLabel
            ) {
                progress(event)
            }
        }

        func emitForegroundWait(
            for group: (uuid: String, items: [Insta360PendingSidecar.WithDir]),
            ssid: String,
            cameraLabel: String?,
            item: Insta360WiFiDownloader.BatchItem?
        ) {
            for event in Self.foregroundWaitProgressEvents(
                for: group,
                ssid: ssid,
                cameraLabel: cameraLabel,
                episodeDir: item?.episodeDir,
                streamId: item?.streamId
            ) {
                progress(event)
            }
        }

        // Cameras are collected sequentially because iOS can join only one
        // camera Wi-Fi AP at a time. Prefetch every target BLE pairing first
        // so the existing per-controller heartbeat keeps waiting cameras
        // awake while an earlier camera is downloading.
        var prefetchedUUIDs: [String] = []
        defer {
            let toCleanup = prefetchedUUIDs
            if !toCleanup.isEmpty {
                Task { [toCleanup] in
                    for uuid in toCleanup {
                        try? await Insta360Scanner.shared.unpair(uuid: uuid)
                    }
                }
            }
        }

        for group in groups {
            emitGroupPhase(group, phase: "scanning")
        }
        let prefetch = await Self.prefetchPairCameras(groups) { uuid, preferredName in
            try await Insta360Scanner.shared.pair(
                uuid: uuid,
                preferredName: preferredName)
        }
        prefetchedUUIDs = prefetch.prefetchedUUIDs
        if prefetch.wasCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()

        var results: [Result] = []

        // iOS can only be on one WiFi AP at a time — process cameras sequentially.
        for (uuid, group) in groups {
            try Task.checkCancellation()
            do {
                emitGroupPhase((uuid, group), phase: "pairing")
                try await Insta360Scanner.shared.pair(
                    uuid: uuid,
                    preferredName: group.first?.sidecar.bleName)
                try Task.checkCancellation()
                let ble = try await Insta360Scanner.shared.controller(forUUID: uuid)
                try? await ble.enableWiFiForDownload()
                let creds = try await ble.wifiCredentials()
                try Task.checkCancellation()

                let batchItems = group.map { item in
                    Insta360WiFiDownloader.BatchItem(
                        episodeDir: item.episodeDir,
                        streamId: item.sidecar.streamId,
                        remoteFileURI: item.sidecar.cameraFileURI,
                        destination: item.episodeDir.appendingPathComponent(
                            "\(item.sidecar.streamId).mp4"),
                        bleAckMonotonicNs: item.sidecar.bleAckMonotonicNs,
                        sidecar: item.sidecar)
                }

                emitGroupPhase(
                    (uuid, group),
                    phase: "awaiting_wifi_join",
                    ssid: creds.ssid,
                    cameraLabel: group.first?.sidecar.bleName)
                let downloader = Insta360WiFiDownloader()
                let batchResults = await downloader.downloadBatch(
                    ssid: creds.ssid,
                    passphrase: creds.passphrase,
                    items: batchItems,
                    onItemStart: { batchItem in
                        progress(Progress(
                            episodeDir: batchItem.episodeDir,
                            streamId: batchItem.streamId,
                            bleUuid: uuid,
                            phase: "downloading",
                            fraction: 0))
                    },
                    onForegroundWait: { batchItem in
                        emitForegroundWait(
                            for: (uuid, group),
                            ssid: creds.ssid,
                            cameraLabel: group.first?.sidecar.bleName,
                            item: batchItem)
                    },
                    progress: { batchItem, fraction in
                        progress(Progress(
                            episodeDir: batchItem.episodeDir,
                            streamId: batchItem.streamId,
                            bleUuid: uuid,
                            phase: "downloading",
                            fraction: fraction))
                    })
                try Task.checkCancellation()

                for br in batchResults {
                    try Task.checkCancellation()
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
                            filePath: br.filePaths.first ?? br.item.destination,
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
        for group in groups {
            emitGroupPhase(group, phase: "restoringWiFi", fraction: 1)
        }
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
    private func discoverUUIDs(
        _ needed: Set<String>,
        preferredNamesByUUID: [String: String],
        timeoutSeconds: UInt64
    ) async throws {
        await Insta360Scanner.shared.stopScan()
        let stream = try await Insta360Scanner.shared.scan()

        let timeout = Task { [needed] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            await Insta360Scanner.shared.stopScan()
            _ = needed   // silence captured-but-unused under release builds
        }

        var seen: Set<String> = []
        for await camera in stream {
            if let matched = await matchedNeededUUID(
                for: camera,
                needed: needed,
                preferredNamesByUUID: preferredNamesByUUID
            ) {
                seen.insert(matched)
            }
            if needed.isSubset(of: seen) {
                await Insta360Scanner.shared.stopScan()
                break
            }
        }
        timeout.cancel()
    }

    private func matchedNeededUUID(
        for camera: DiscoveredInsta360,
        needed: Set<String>,
        preferredNamesByUUID: [String: String]
    ) async -> String? {
        if needed.contains(camera.uuid) { return camera.uuid }
        let cameraSerial = Insta360BLEController.extractSerialLast6(fromBLEName: camera.name)

        for (uuid, name) in preferredNamesByUUID {
            guard needed.contains(uuid),
                  let preferredSerial = Insta360BLEController.extractSerialLast6(fromBLEName: name),
                  preferredSerial == cameraSerial
            else { continue }
            return uuid
        }

        for uuid in needed {
            guard let record = await Insta360IdentityStore.shared.record(forUUID: uuid),
                  record.serialLast6 == cameraSerial
            else { continue }
            return uuid
        }

        return nil
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
