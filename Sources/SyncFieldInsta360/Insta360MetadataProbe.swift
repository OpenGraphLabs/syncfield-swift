import Foundation

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK
#endif

/// Diagnostic probe that exercises every Insta360 SDK metadata surface we
/// know about and emits structured `[INSTA360.PROBE.*]` log lines so we can
/// verify (1) which APIs actually return data on the GO3S over WiFi, (2) what
/// fields come back, and (3) whether listing results look complete relative
/// to the SD card's reported storage.
///
/// This is intentionally NOT wired into the recording / collect critical
/// path — it's a one-shot diagnostic invoked from the bridge / debug UI. It
/// reuses the same BLE pair + WiFi-coordinator dance as `Insta360Collector`
/// so the probe behaves like a real collect attempt.
///
/// Greppable log surface:
///
///   [INSTA360.PROBE]           top-level orchestration markers
///   [INSTA360.PROBE.storage]   getOptionsWithTypes → INSCameraStorageStatus
///   [INSTA360.PROBE.list.*]    every listing API (edit, http-video, mnd-index)
///   [INSTA360.PROBE.file.*]    per-file metadata (mnd, thumbnail)
///   [INSTA360.PROBE.summary]   final per-section summary tables
public enum Insta360MetadataProbe {

    // MARK: - Public report types

    public struct Report: Sendable {
        public let cameraUUID: String
        public let cameraName: String?
        public let startedAtIso: String
        public let totalMs: Int
        public let storage: StorageReport?
        public let listings: [ListingReport]
        public let perFile: [PerFileReport]
        public let warnings: [String]
    }

    public struct StorageReport: Sendable {
        public let cardState: Int
        public let cardLocation: Int
        public let freeBytes: Int64
        public let totalBytes: Int64
        public let usedBytes: Int64
    }

    public struct ListingReport: Sendable {
        public let api: String
        public let durationMs: Int
        public let ok: Bool
        public let errorMessage: String?
        /// File count returned by the API. For paginated APIs this is the
        /// total across all pages we received.
        public let fileCount: Int?
        /// Server-reported total count (only set by paginated APIs that
        /// expose `INSCameraResources.cameraTotalCount` / `.sdTotalCount`).
        public let serverTotalCount: Int?
        public let sampleFiles: [SampleFile]
        public let extras: [String: String]
    }

    public struct SampleFile: Sendable {
        public let uri: String
        public let durationSec: Double?
        public let sizeBytes: UInt64?
    }

    public struct PerFileReport: Sendable {
        public let uri: String
        public let mnd: [MndResult]
        public let httpThumbnailBytes: Int?
        public let httpThumbnailError: String?
        public let httpThumbnailMs: Int?
    }

    public struct MndResult: Sendable {
        /// `INSFileMndType` raw value. 1=Metadata, 2=Thumbnail, 3=Gyro,
        /// 4=Exposure, 5=ExtThumbnail, 6=FramePts, 7=Gps, 10=Highlight,
        /// 18=Editor, 26=APEI.
        public let type: Int
        public let typeName: String
        public let bytes: Int?
        public let ok: Bool
        public let errorMessage: String?
        public let durationMs: Int
        /// First 16 bytes hex — handy when payload is a known marker
        /// (e.g. INSExtraInfo tail uses `8db42d69` magic).
        public let headHex: String?
        public let transport: String
    }

    // MARK: - Public entry point

    #if canImport(INSCameraServiceSDK)
    /// Probe a single Insta360 camera. Pairs over BLE if not paired, joins the
    /// camera AP, hits every metadata API in sequence, restores WiFi, returns
    /// a structured report. Always logs `[INSTA360.PROBE]` lines regardless
    /// of return; failure modes still produce a Report so the caller can
    /// surface "what we tried" alongside what worked.
    ///
    /// - Parameter sampleLimit: how many files to deep-probe (per-file mnd +
    ///   thumbnail). Default 3; bump to 5 for richer captures.
    public static func probe(
        uuid: String,
        preferredName: String? = nil,
        sampleLimit: Int = 3
    ) async throws -> Report {
        let trimmedUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUUID.isEmpty else {
            throw Insta360Error.notPaired
        }

        let startedAt = Date()
        let startedAtIso = ISO8601DateFormatter().string(from: startedAt)
        InstaLog.log(.probe, level: .state,
                     "probe_started",
                     ["uuid": trimmedUUID, "name": preferredName ?? "nil",
                      "sampleLimit": sampleLimit, "startedAt": startedAtIso])

        var warnings: [String] = []

        // 1. BLE pair + WiFi creds (mirrors Insta360Collector.performListFiles).
        try await Insta360Scanner.shared.pair(
            uuid: trimmedUUID,
            preferredName: preferredName)
        let ble = try await Insta360Scanner.shared.controller(forUUID: trimmedUUID)
        try? await ble.enableWiFiForDownload()
        let creds = try await ble.wifiCredentials()
        InstaLog.log(.probe, level: .info,
                     "ble_ready_credentials_obtained",
                     ["ssid": creds.ssid])

        // 2. Bind to WiFi via the central coordinator and run the probe core.
        let downloader = Insta360WiFiDownloader()
        let report = try await Insta360ConnectionCoordinator.shared.withWiFi(
            bindingKey: trimmedUUID
        ) { _ in
            try await downloader.runMetadataProbe(
                ssid: creds.ssid,
                passphrase: creds.passphrase,
                sampleLimit: sampleLimit,
                cameraUUID: trimmedUUID,
                cameraName: preferredName,
                startedAtIso: startedAtIso,
                warnings: &warnings)
        }

        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        InstaLog.log(.probe, level: .state,
                     "probe_completed",
                     ["uuid": trimmedUUID,
                      "totalMs": totalMs,
                      "listings": report.listings.count,
                      "perFile": report.perFile.count,
                      "warnings": warnings.count])

        return Report(
            cameraUUID: trimmedUUID,
            cameraName: preferredName,
            startedAtIso: startedAtIso,
            totalMs: totalMs,
            storage: report.storage,
            listings: report.listings,
            perFile: report.perFile,
            warnings: warnings)
    }
    #endif
}

// MARK: - INSFileMndType naming (kept in this file so the probe is the
// single source of truth for the type → name mapping used in logs).

internal enum InstaMndTypeName {
    static func name(for raw: Int) -> String {
        switch raw {
        case 0:  return "All"
        case 1:  return "Metadata"
        case 2:  return "Thumbnail"
        case 3:  return "Gyro"
        case 4:  return "Exposure"
        case 5:  return "ExtThumbnail"
        case 6:  return "FramePts"
        case 7:  return "Gps"
        case 10: return "Highlight"
        case 18: return "Editor"
        case 26: return "APEI"
        default: return "Unknown(\(raw))"
        }
    }

    /// Types the probe will request per sampled file. Kept conservative;
    /// camera firmware ignores unsupported types and we log per-type errors.
    static let probeTypes: [Int] = [1, 2, 3, 4, 7]
}

#if canImport(INSCameraServiceSDK)

/// Local continuation gate. Mirrors the private one inside
/// `Insta360WiFiDownloader.swift` but supports both throwing and
/// non-throwing continuations — every probe step either returns a
/// `Result`-shaped report value (non-throwing) or rethrows (throwing).
fileprivate final class ProbeGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    func resume(_ cont: CheckedContinuation<Value, Error>, returning value: Value) {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        isOpen = false
        cont.resume(returning: value)
    }
    func resume(_ cont: CheckedContinuation<Value, Error>, throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        isOpen = false
        cont.resume(throwing: error)
    }
    func resume(_ cont: CheckedContinuation<Value, Never>, returning value: Value) {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        isOpen = false
        cont.resume(returning: value)
    }
}

extension Insta360WiFiDownloader {

    /// Internal struct so the probe orchestrator and `runMetadataProbe` can
    /// share a return shape without exposing it publicly.
    internal struct InternalProbeBundle: Sendable {
        let storage: Insta360MetadataProbe.StorageReport?
        let listings: [Insta360MetadataProbe.ListingReport]
        let perFile: [Insta360MetadataProbe.PerFileReport]
    }

    /// Internal probe entry. Assumes the WiFi coordinator already bound the
    /// AP. Joins the camera hotspot, opens the SDK socket, runs every probe
    /// step (logging each), tears down. Failures within a probe step turn
    /// into warnings — the probe never aborts on a single API failure.
    internal func runMetadataProbe(
        ssid: String,
        passphrase: String,
        sampleLimit: Int,
        cameraUUID: String,
        cameraName: String?,
        startedAtIso: String,
        warnings: inout [String]
    ) async throws -> InternalProbeBundle {
        try await applyHotspot(
            ssid: ssid,
            passphrase: passphrase,
            applyTimeoutSeconds: 10)
        try await waitForReachability(attempts: 8)

        // Two-shot socket setup, identical to listFiles', so the probe sees
        // the same socket-ready behaviour as production listing.
        var socketReady = false
        for attempt in 1...2 {
            INSCameraManager.socket().shutdown()
            INSCameraManager.socket().setup()
            socketReady = await waitForSocketCameraReady(
                timeoutSeconds: attempt == 1 ? 3.0 : 5.0)
            if !socketReady {
                try await Task.sleep(nanoseconds: attempt == 1 ? 500_000_000 : 800_000_000)
            }
            INSCameraManager.socket().commandsImpl.sendHeartbeats(with: nil)
            if socketReady { break }
        }
        InstaLog.log(.probe, level: .info,
                     "socket_setup",
                     ["ready": socketReady])

        var storage: Insta360MetadataProbe.StorageReport?
        var listings: [Insta360MetadataProbe.ListingReport] = []
        var perFile: [Insta360MetadataProbe.PerFileReport] = []

        // 1. Storage status
        do {
            storage = try await probeStorageStatus()
            if let storage {
                InstaLog.log(.probe, role: "storage", level: .state,
                             "storage_status_ok",
                             ["freeBytes": storage.freeBytes,
                              "totalBytes": storage.totalBytes,
                              "usedBytes": storage.usedBytes,
                              "cardState": storage.cardState,
                              "cardLocation": storage.cardLocation])
            }
        } catch {
            warnings.append("storage_status: \(error.localizedDescription)")
            InstaLog.log(.probe, role: "storage", level: .warn,
                         "storage_status_failed",
                         ["error": error.localizedDescription])
        }

        // 2. Listing APIs
        let editListing = await probeFetchFileEditList()
        listings.append(editListing)
        if !editListing.ok { warnings.append("fetchFileEditList: \(editListing.errorMessage ?? "unknown")") }

        let httpVideoListing = await probeHTTPFetchVideoList()
        listings.append(httpVideoListing)
        if !httpVideoListing.ok { warnings.append("http.fetchVideoList: \(httpVideoListing.errorMessage ?? "unknown")") }

        let mndIndexListing = await probeHTTPFetchFileMnds()
        listings.append(mndIndexListing)
        if !mndIndexListing.ok { warnings.append("http.fetchFileMnds: \(mndIndexListing.errorMessage ?? "unknown")") }

        // Dynamic-dispatch attempts at USB-only listing APIs over the same
        // socket. These will most likely return "selector not found" but the
        // attempt is logged either way so we have evidence in the probe.
        let usbVideoListing = await probeDynamic(
            selector: "fetchVideoListWithCompletion:",
            api: "commandsImpl.fetchVideoListWithCompletion(usb)")
        listings.append(usbVideoListing)

        let completeListing = await probeDynamic(
            selector: "fetchCompleteVideoListWithCompletion:",
            api: "commandsImpl.fetchCompleteVideoListWithCompletion(usb)")
        listings.append(completeListing)

        // Paginated USB list (`fetchVideoListWithOptions:completion:`). If
        // it responds, the result is an `INSCameraResources` with
        // `cameraResources`/`sdResources` arrays of `INSCameraVideoInfo`
        // (which carry `totalTime` + `fileSize`). This is the closest path
        // we have to a "canonical" duration source if the flat
        // `fetchVideoList` isn't available on this firmware.
        let paginatedListing = await probePaginatedVideoList()
        listings.append(paginatedListing)
        if !paginatedListing.ok { warnings.append("fetchVideoListWithOptions: \(paginatedListing.errorMessage ?? "unknown")") }

        // 3. Per-file metadata + thumbnail (sample from the richest listing
        // we got: prefer paginated -> http-video-list -> edit-list).
        let sampleUris = selectSampleURIs(
            preferred: paginatedListing.sampleFiles,
            fallback: httpVideoListing.sampleFiles.isEmpty
                ? editListing.sampleFiles
                : httpVideoListing.sampleFiles,
            limit: sampleLimit)

        InstaLog.log(.probe, level: .info,
                     "per_file_sample_picked",
                     ["count": sampleUris.count,
                      "uris": sampleUris.prefix(5).map { $0 }])

        for uri in sampleUris {
            let report = await probePerFile(uri: uri)
            perFile.append(report)
        }

        // Cleanup
        INSCameraManager.socket().shutdown()
        await restoreSystemWiFiAfterCameraOperation(ssid: ssid, context: "metadataProbe")

        // Summary log lines — designed to be easily grep'd as a single block
        // after a probe run.
        emitSummary(
            cameraUUID: cameraUUID,
            cameraName: cameraName,
            startedAtIso: startedAtIso,
            storage: storage,
            listings: listings,
            perFile: perFile,
            warnings: warnings)

        return InternalProbeBundle(
            storage: storage,
            listings: listings,
            perFile: perFile)
    }

    // MARK: - Step: storage status

    private func probeStorageStatus() async throws -> Insta360MetadataProbe.StorageReport {
        let cmd = INSCameraManager.socket().commandsImpl as NSObject
        let sel = NSSelectorFromString("getOptionsWithTypes:completion:")
        guard cmd.responds(to: sel) else {
            throw Insta360Error.downloadFailed("getOptionsWithTypes selector unavailable")
        }

        let started = Date()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.StorageReport, Error>) in
            let gate = ProbeGate<Insta360MetadataProbe.StorageReport>()
            let storageType: UInt16 = 20 // INSCameraOptionsTypeStorageState
            let timeout = DispatchWorkItem {
                gate.resume(cont, throwing: Insta360Error.downloadFailed("getOptionsWithTypes(storageState) timed out"))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: timeout)

            let block: @convention(block) (NSError?, AnyObject?, NSArray?) -> Void = { error, options, _ in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "storage", level: .warn,
                                 "getOptionsWithTypes_failed",
                                 ["ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, throwing: error)
                    return
                }
                guard let opts = options,
                      let status = opts.value(forKey: "storageStatus") as? NSObject
                else {
                    gate.resume(cont, throwing: Insta360Error.downloadFailed("storageStatus missing"))
                    return
                }
                let cardState = (status.value(forKey: "cardState") as? NSNumber)?.intValue ?? -1
                let cardLocation = (status.value(forKey: "cardLocation") as? NSNumber)?.intValue ?? -1
                let freeBytes = (status.value(forKey: "freeSpace") as? NSNumber)?.int64Value ?? 0
                let totalBytes = (status.value(forKey: "totalSpace") as? NSNumber)?.int64Value ?? 0
                let report = Insta360MetadataProbe.StorageReport(
                    cardState: cardState,
                    cardLocation: cardLocation,
                    freeBytes: freeBytes,
                    totalBytes: totalBytes,
                    usedBytes: max(0, totalBytes - freeBytes))
                gate.resume(cont, returning: report)
            }

            _ = cmd.perform(sel, with: [NSNumber(value: storageType)], with: block)
        }
    }

    // MARK: - Step: fetchFileEditList (basic commands, known to work)

    private func probeFetchFileEditList() async -> Insta360MetadataProbe.ListingReport {
        let started = Date()
        let cmd = INSCameraManager.socket().commandsImpl
        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.ListingReport, Never>) in
            let gate = ProbeGate<Insta360MetadataProbe.ListingReport>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    api: "commandsImpl.fetchFileEditList",
                    durationMs: ms, ok: false,
                    errorMessage: "timed out after 12s",
                    fileCount: nil, serverTotalCount: nil,
                    sampleFiles: [], extras: [:]))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)
            let storageType = INSStorageType(rawValue: 0b0011)
            cmd.fetchFileEditList(with: storageType) { error, list in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "list.editList", level: .warn,
                                 "fetchFileEditList_failed",
                                 ["ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        api: "commandsImpl.fetchFileEditList",
                        durationMs: ms, ok: false,
                        errorMessage: error.localizedDescription,
                        fileCount: nil, serverTotalCount: nil,
                        sampleFiles: [], extras: [:]))
                    return
                }
                var uris: [String] = []
                var samples: [Insta360MetadataProbe.SampleFile] = []
                let sdArr = (list?.sdEditInfolist as? [INSCameraEditInfo]) ?? []
                let camArr = (list?.cameraEditInfolist as? [INSCameraEditInfo]) ?? []

                // Detailed per-file diagnostic for the first 5 entries — this
                // is where we'll see whether `favoriteInfo` is populated for
                // non-favorited files, which dictates whether the
                // modify-timestamp duration heuristic can work at all.
                var perFileDiag: [String] = []
                var withFavoriteInfo = 0
                var withModifyTs = 0
                for item in (sdArr + camArr).prefix(5) {
                    let path = item.filePath ?? "<nil>"
                    let hasFav = item.favoriteInfo != nil
                    let modTs = item.favoriteInfo?.modifyTimestamp ?? 0
                    if hasFav { withFavoriteInfo += 1 }
                    if modTs > 0 { withModifyTs += 1 }
                    perFileDiag.append(
                        "\(path) favoriteInfo=\(hasFav ? "yes" : "nil") modifyTs=\(modTs)")
                }
                // Aggregate counts across ALL items (not just first 5) so we
                // know how prevalent the missing-timestamp case is.
                var allFavCount = 0
                var allModTsCount = 0
                for item in (sdArr + camArr) {
                    if item.favoriteInfo != nil { allFavCount += 1 }
                    if (item.favoriteInfo?.modifyTimestamp ?? 0) > 0 { allModTsCount += 1 }
                }
                InstaLog.log(.probe, role: "list.editList.diag", level: .info,
                             "edit_list_per_file_diagnostic",
                             ["total": sdArr.count + camArr.count,
                              "withFavoriteInfoAll": allFavCount,
                              "withModifyTsAll": allModTsCount,
                              "sample": perFileDiag])

                for item in sdArr + camArr {
                    if let path = item.filePath, !path.isEmpty {
                        uris.append(path)
                        if samples.count < 5 {
                            samples.append(.init(uri: path, durationSec: nil, sizeBytes: nil))
                        }
                    }
                }
                let extras: [String: String] = [
                    "sdEditInfolist": String(sdArr.count),
                    "cameraEditInfolist": String(camArr.count),
                    "withFavoriteInfoAll": String(allFavCount),
                    "withModifyTsAll": String(allModTsCount),
                ]
                InstaLog.log(.probe, role: "list.editList", level: .info,
                             "fetchFileEditList_ok",
                             ["ms": ms,
                              "sd": sdArr.count,
                              "camera": camArr.count,
                              "total": uris.count,
                              "withFavoriteInfoAll": allFavCount,
                              "withModifyTsAll": allModTsCount,
                              "head": uris.prefix(3).joined(separator: ",")])
                gate.resume(cont, returning: .init(
                    api: "commandsImpl.fetchFileEditList",
                    durationMs: ms, ok: true,
                    errorMessage: nil,
                    fileCount: uris.count, serverTotalCount: nil,
                    sampleFiles: samples, extras: extras))
            }
        }
    }

    // MARK: - Step: HTTP fetchVideoList (returns totalTime + fileSize)

    private func probeHTTPFetchVideoList() async -> Insta360MetadataProbe.ListingReport {
        let started = Date()
        let http = INSCameraHTTPManager.socket()
        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.ListingReport, Never>) in
            let gate = ProbeGate<Insta360MetadataProbe.ListingReport>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    api: "http.fetchVideoList",
                    durationMs: ms, ok: false,
                    errorMessage: "timed out after 12s",
                    fileCount: nil, serverTotalCount: nil,
                    sampleFiles: [], extras: [:]))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)

            let task = http.fetchVideoList { error, list in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "list.http", level: .warn,
                                 "fetchVideoList_failed",
                                 ["ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        api: "http.fetchVideoList",
                        durationMs: ms, ok: false,
                        errorMessage: error.localizedDescription,
                        fileCount: nil, serverTotalCount: nil,
                        sampleFiles: [], extras: [:]))
                    return
                }
                var samples: [Insta360MetadataProbe.SampleFile] = []
                var count = 0
                var withDurationCount = 0
                var withSizeCount = 0
                if let arr = list as? [AnyObject] {
                    for obj in arr {
                        count += 1
                        let uri = (obj.value(forKey: "uri") as? String) ?? ""
                        let dur = (obj.value(forKey: "totalTime") as? NSNumber)?.doubleValue
                        let size = (obj.value(forKey: "fileSize") as? NSNumber)?.uint64Value
                        if (dur ?? 0) > 0 { withDurationCount += 1 }
                        if (size ?? 0) > 0 { withSizeCount += 1 }
                        if samples.count < 5, !uri.isEmpty {
                            samples.append(.init(uri: uri, durationSec: dur, sizeBytes: size))
                        }
                    }
                }
                InstaLog.log(.probe, role: "list.http", level: .info,
                             "fetchVideoList_ok",
                             ["ms": ms,
                              "count": count,
                              "withDuration": withDurationCount,
                              "withSize": withSizeCount,
                              "head": samples.prefix(3).map { $0.uri }])
                gate.resume(cont, returning: .init(
                    api: "http.fetchVideoList",
                    durationMs: ms, ok: true,
                    errorMessage: nil,
                    fileCount: count, serverTotalCount: nil,
                    sampleFiles: samples,
                    extras: [
                        "withDuration": String(withDurationCount),
                        "withSize": String(withSizeCount),
                    ]))
            }
            if task == nil {
                timeout.cancel()
                gate.resume(cont, returning: .init(
                    api: "http.fetchVideoList",
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    ok: false,
                    errorMessage: "task=nil",
                    fileCount: nil, serverTotalCount: nil,
                    sampleFiles: [], extras: [:]))
            }
        }
    }

    // MARK: - Step: HTTP fetchFileMnds (index of metadata sidecars)

    private func probeHTTPFetchFileMnds() async -> Insta360MetadataProbe.ListingReport {
        let started = Date()
        let http = INSCameraHTTPManager.socket() as NSObject
        let sel = NSSelectorFromString("fetchFileMndsWithCompletion:")
        guard http.responds(to: sel) else {
            return .init(
                api: "http.fetchFileMnds",
                durationMs: 0, ok: false,
                errorMessage: "selector unavailable",
                fileCount: nil, serverTotalCount: nil,
                sampleFiles: [], extras: [:])
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.ListingReport, Never>) in
            let gate = ProbeGate<Insta360MetadataProbe.ListingReport>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    api: "http.fetchFileMnds",
                    durationMs: ms, ok: false,
                    errorMessage: "timed out after 10s",
                    fileCount: nil, serverTotalCount: nil,
                    sampleFiles: [], extras: [:]))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)

            let block: @convention(block) (NSError?, NSArray?) -> Void = { error, arr in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "list.mndIndex", level: .warn,
                                 "fetchFileMnds_failed",
                                 ["ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        api: "http.fetchFileMnds",
                        durationMs: ms, ok: false,
                        errorMessage: error.localizedDescription,
                        fileCount: nil, serverTotalCount: nil,
                        sampleFiles: [], extras: [:]))
                    return
                }
                var samples: [Insta360MetadataProbe.SampleFile] = []
                var typeCounts: [Int: Int] = [:]
                let count = arr?.count ?? 0
                for raw in (arr ?? []) {
                    guard let obj = raw as? NSObject else { continue }
                    let uri = (obj.value(forKey: "uri") as? String) ?? ""
                    let type = (obj.value(forKey: "type") as? NSNumber)?.intValue ?? -1
                    typeCounts[type, default: 0] += 1
                    if samples.count < 5 {
                        samples.append(.init(uri: "\(uri)#type=\(type)",
                                             durationSec: nil, sizeBytes: nil))
                    }
                }
                let typeSummary = typeCounts.keys.sorted().map {
                    "\(InstaMndTypeName.name(for: $0)):\(typeCounts[$0]!)"
                }.joined(separator: ",")
                InstaLog.log(.probe, role: "list.mndIndex", level: .info,
                             "fetchFileMnds_ok",
                             ["ms": ms,
                              "count": count,
                              "typeSummary": typeSummary])
                gate.resume(cont, returning: .init(
                    api: "http.fetchFileMnds",
                    durationMs: ms, ok: true,
                    errorMessage: nil,
                    fileCount: count, serverTotalCount: nil,
                    sampleFiles: samples,
                    extras: ["types": typeSummary]))
            }
            _ = http.perform(sel, with: block)
        }
    }

    // MARK: - Step: paginated USB fetchVideoListWithOptions:

    /// `fetchVideoListWithOptions:completion:` returns an
    /// `INSCameraResources` whose `cameraResources` / `sdResources` arrays
    /// hold `INSCameraVideoInfo` objects with `totalTime` + `fileSize`. If
    /// this path is alive on GO3S firmware over WiFi, it's the cleanest
    /// duration source we have. Selector availability is checked
    /// dynamically since `commandsImpl` doesn't formally conform to
    /// `INSCameraSimpleUSBCommands`.
    private func probePaginatedVideoList() async -> Insta360MetadataProbe.ListingReport {
        let started = Date()
        let api = "commandsImpl.fetchVideoListWithOptions(paginated)"
        let cmd = INSCameraManager.socket().commandsImpl as NSObject
        let sel = NSSelectorFromString("fetchVideoListWithOptions:completion:")
        guard cmd.responds(to: sel) else {
            InstaLog.log(.probe, role: "list.paginated", level: .debug,
                         "paginated_selector_unavailable",
                         ["selector": "fetchVideoListWithOptions:completion:"])
            return .init(
                api: api, durationMs: 0, ok: false,
                errorMessage: "selector unavailable on commandsImpl",
                fileCount: nil, serverTotalCount: nil,
                sampleFiles: [], extras: [:])
        }

        // Build INSGetFileListOptions(start: 0, limit: 10, type: both).
        // `INSGetFileListOptions` is plain NSObject so KVC works.
        guard let optionsClass = NSClassFromString("INSGetFileListOptions") as? NSObject.Type else {
            return .init(
                api: api, durationMs: 0, ok: false,
                errorMessage: "INSGetFileListOptions class missing",
                fileCount: nil, serverTotalCount: nil,
                sampleFiles: [], extras: [:])
        }
        let options = optionsClass.init()
        options.setValue(NSNumber(value: UInt(0)), forKey: "start")
        options.setValue(NSNumber(value: UInt(10)), forKey: "limit")
        options.setValue(NSNumber(value: UInt(0b0011)), forKey: "type")

        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.ListingReport, Never>) in
            let gate = ProbeGate<Insta360MetadataProbe.ListingReport>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    api: api, durationMs: ms, ok: false,
                    errorMessage: "timed out after 12s",
                    fileCount: nil, serverTotalCount: nil,
                    sampleFiles: [], extras: [:]))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)

            let block: @convention(block) (NSError?, NSObject?) -> Void = { error, res in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "list.paginated", level: .warn,
                                 "paginated_failed",
                                 ["ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        api: api, durationMs: ms, ok: false,
                        errorMessage: error.localizedDescription,
                        fileCount: nil, serverTotalCount: nil,
                        sampleFiles: [], extras: [:]))
                    return
                }
                let camCount = (res?.value(forKey: "cameraTotalCount") as? NSNumber)?.intValue ?? -1
                let sdCount = (res?.value(forKey: "sdTotalCount") as? NSNumber)?.intValue ?? -1
                let camRes = (res?.value(forKey: "cameraResources") as? [NSObject]) ?? []
                let sdRes = (res?.value(forKey: "sdResources") as? [NSObject]) ?? []
                let merged = camRes + sdRes
                var samples: [Insta360MetadataProbe.SampleFile] = []
                var withDur = 0
                var withSize = 0
                for obj in merged.prefix(10) {
                    let uri = (obj.value(forKey: "uri") as? String) ?? ""
                    let dur = (obj.value(forKey: "totalTime") as? NSNumber)?.doubleValue
                    let size = (obj.value(forKey: "fileSize") as? NSNumber)?.uint64Value
                    if (dur ?? 0) > 0 { withDur += 1 }
                    if (size ?? 0) > 0 { withSize += 1 }
                    if samples.count < 5, !uri.isEmpty {
                        // INSCameraVideoInfo's `totalTime` is documented as
                        // milliseconds in the wider SDK; surface raw here so
                        // the log reader can spot the unit.
                        samples.append(.init(uri: uri, durationSec: dur, sizeBytes: size))
                    }
                }
                InstaLog.log(.probe, role: "list.paginated", level: .info,
                             "paginated_ok",
                             ["ms": ms,
                              "cameraTotalCount": camCount,
                              "sdTotalCount": sdCount,
                              "received": merged.count,
                              "withDuration": withDur,
                              "withSize": withSize])
                gate.resume(cont, returning: .init(
                    api: api, durationMs: ms, ok: true,
                    errorMessage: nil,
                    fileCount: merged.count,
                    serverTotalCount: camCount + sdCount,
                    sampleFiles: samples,
                    extras: [
                        "withDuration": String(withDur),
                        "withSize": String(withSize),
                        "cameraTotalCount": String(camCount),
                        "sdTotalCount": String(sdCount),
                    ]))
            }
            _ = cmd.perform(sel, with: options, with: block)
        }
    }

    // MARK: - Step: HEAD per sample file (Content-Length sanity)

    /// Per-file `headResourceWithURI:` to confirm whether HTTP HEAD is
    /// alive on this firmware. Doesn't return the size in the callback
    /// shape we have, but a clean ack vs. error is enough signal for now;
    /// later we can switch to a Range request if we want fileSize.
    private func probeHTTPHead(uri: String) async -> (ok: Bool, ms: Int, error: String?) {
        let started = Date()
        let http = INSCameraHTTPManager.socket() as NSObject
        let sel = NSSelectorFromString("headResourceWithURI:completion:")
        guard http.responds(to: sel) else {
            return (false, 0, "selector unavailable")
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Int, String?), Never>) in
            let lock = NSLock()
            var fired = false
            func resumeOnce(_ value: (Bool, Int, String?)) {
                lock.lock(); defer { lock.unlock() }
                guard !fired else { return }
                fired = true
                cont.resume(returning: value)
            }
            let timeout = DispatchWorkItem {
                resumeOnce((false, Int(Date().timeIntervalSince(started) * 1000), "timed out after 6s"))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: timeout)

            let block: @convention(block) (NSError?) -> Void = { error in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                resumeOnce((error == nil, ms, error?.localizedDescription))
            }
            _ = http.perform(sel, with: uri as NSString, with: block)
        }
    }

    // MARK: - Step: dynamic-dispatch attempt at USB-only listing APIs

    private func probeDynamic(
        selector selectorName: String,
        api: String
    ) async -> Insta360MetadataProbe.ListingReport {
        let started = Date()
        let cmd = INSCameraManager.socket().commandsImpl as NSObject
        let sel = NSSelectorFromString(selectorName)
        if !cmd.responds(to: sel) {
            InstaLog.log(.probe, role: "list.usbDyn", level: .debug,
                         "dynamic_selector_unavailable",
                         ["api": api, "selector": selectorName])
            return .init(
                api: api, durationMs: 0, ok: false,
                errorMessage: "selector unavailable on commandsImpl (expected — USB-only on iOS WiFi socket)",
                fileCount: nil, serverTotalCount: nil,
                sampleFiles: [], extras: [:])
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.ListingReport, Never>) in
            let gate = ProbeGate<Insta360MetadataProbe.ListingReport>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    api: api, durationMs: ms, ok: false,
                    errorMessage: "timed out after 10s",
                    fileCount: nil, serverTotalCount: nil,
                    sampleFiles: [], extras: [:]))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)

            let block: @convention(block) (NSError?, NSArray?) -> Void = { error, arr in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "list.usbDyn", level: .warn,
                                 "dynamic_call_failed",
                                 ["api": api, "ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        api: api, durationMs: ms, ok: false,
                        errorMessage: error.localizedDescription,
                        fileCount: nil, serverTotalCount: nil,
                        sampleFiles: [], extras: [:]))
                    return
                }
                let count = arr?.count ?? 0
                var samples: [Insta360MetadataProbe.SampleFile] = []
                for raw in (arr ?? []) {
                    guard let obj = raw as? NSObject else { continue }
                    let uri = (obj.value(forKey: "uri") as? String) ?? ""
                    let dur = (obj.value(forKey: "totalTime") as? NSNumber)?.doubleValue
                    let size = (obj.value(forKey: "fileSize") as? NSNumber)?.uint64Value
                    if samples.count < 5, !uri.isEmpty {
                        samples.append(.init(uri: uri, durationSec: dur, sizeBytes: size))
                    }
                }
                InstaLog.log(.probe, role: "list.usbDyn", level: .info,
                             "dynamic_call_ok",
                             ["api": api, "ms": ms, "count": count])
                gate.resume(cont, returning: .init(
                    api: api, durationMs: ms, ok: true,
                    errorMessage: nil,
                    fileCount: count, serverTotalCount: nil,
                    sampleFiles: samples, extras: [:]))
            }
            _ = cmd.perform(sel, with: block)
        }
    }

    // MARK: - Per-file probe

    private func selectSampleURIs(
        preferred: [Insta360MetadataProbe.SampleFile],
        fallback: [Insta360MetadataProbe.SampleFile],
        limit: Int
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ s: String) {
            if !Self.isUserFacingVideo(s) { return }
            if !seen.contains(s) {
                seen.insert(s)
                result.append(s)
            }
        }
        for f in preferred { add(f.uri); if result.count >= limit { return result } }
        for f in fallback { add(f.uri); if result.count >= limit { return result } }
        return result
    }

    /// Skip Insta360 low-res preview sidecars (`.lrv`) and any non-video
    /// extension. The paginated listing endpoint returns both `.mp4` and
    /// `.lrv`; only `.mp4` matches what the user actually picks as a wrist
    /// recording, so probe samples should mirror that.
    private static func isUserFacingVideo(_ uri: String) -> Bool {
        let lower = uri.lowercased()
        guard lower.hasSuffix(".mp4") || lower.hasSuffix(".insv") else {
            return false
        }
        return !lower.contains("/lrv_") && !lower.contains(".lrv")
    }

    private func probePerFile(uri: String) async -> Insta360MetadataProbe.PerFileReport {
        InstaLog.log(.probe, role: "file", level: .info,
                     "per_file_probe_start", ["uri": uri])

        var mndResults: [Insta360MetadataProbe.MndResult] = []
        for type in InstaMndTypeName.probeTypes {
            mndResults.append(await probeFileMnd(uri: uri, type: type))
        }

        let thumb = await probeFileThumbnail(uri: uri)

        // HTTP HEAD on the raw file URI. Used to verify the HTTP path is
        // alive at all (the flat fetchVideoList endpoint is dead on this
        // firmware — but HEAD on the resource may still work and gives us a
        // path to fileSize without downloading the whole file).
        let head = await probeHTTPHead(uri: uri)
        InstaLog.log(.probe, role: "file.head", level: head.ok ? .info : .warn,
                     head.ok ? "head_ok" : "head_failed",
                     ["uri": uri, "ms": head.ms,
                      "error": head.error ?? "nil"])

        InstaLog.log(.probe, role: "file", level: .info,
                     "per_file_probe_end",
                     ["uri": uri,
                      "mndOk": mndResults.filter { $0.ok }.count,
                      "mndTotal": mndResults.count,
                      "thumbBytes": thumb.bytes ?? -1,
                      "headOk": head.ok])

        return .init(
            uri: uri,
            mnd: mndResults,
            httpThumbnailBytes: thumb.bytes,
            httpThumbnailError: thumb.error,
            httpThumbnailMs: thumb.ms)
    }

    private func probeFileMnd(uri: String, type: Int) async -> Insta360MetadataProbe.MndResult {
        let started = Date()
        let cmd = INSCameraManager.socket().commandsImpl as NSObject
        let sel = NSSelectorFromString("getFileMndWithURI:type:completion:")
        let typeName = InstaMndTypeName.name(for: type)

        if !cmd.responds(to: sel) {
            InstaLog.log(.probe, role: "file.mnd", level: .debug,
                         "mnd_selector_unavailable",
                         ["uri": uri, "type": type, "typeName": typeName])
            return .init(type: type, typeName: typeName, bytes: nil,
                         ok: false,
                         errorMessage: "getFileMndWithURI selector unavailable on WiFi socket",
                         durationMs: 0, headHex: nil,
                         transport: "commandsImpl")
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360MetadataProbe.MndResult, Never>) in
            let gate = ProbeGate<Insta360MetadataProbe.MndResult>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    type: type, typeName: typeName, bytes: nil,
                    ok: false, errorMessage: "timed out after 12s",
                    durationMs: ms, headHex: nil, transport: "commandsImpl"))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)

            let block: @convention(block) (NSError?, NSData?) -> Void = { error, data in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "file.mnd", level: .warn,
                                 "mnd_call_failed",
                                 ["uri": uri, "type": type, "typeName": typeName,
                                  "ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        type: type, typeName: typeName, bytes: nil,
                        ok: false, errorMessage: error.localizedDescription,
                        durationMs: ms, headHex: nil, transport: "commandsImpl"))
                    return
                }
                let bytes = data?.count ?? 0
                let head = data.flatMap { Self.headHex($0 as Data, count: 16) }
                // Dump a wider hex window for type=1 (Metadata) so we can
                // reverse-engineer the protobuf structure to find duration
                // / resolution / capture-end fields. 256 bytes is enough to
                // cover serial + ~8 more length-prefixed fields without
                // blowing up the log file size.
                let wideHead = (type == 1)
                    ? data.flatMap { Self.headHex($0 as Data, count: 256) }
                    : nil
                InstaLog.log(.probe, role: "file.mnd", level: .info,
                             "mnd_call_ok",
                             ["uri": uri, "type": type, "typeName": typeName,
                              "ms": ms, "bytes": bytes,
                              "head16": head ?? "nil"])
                if let wideHead, !wideHead.isEmpty {
                    // Log on its own line so the wide payload doesn't get
                    // truncated by macOS unified-logging line caps.
                    InstaLog.log(.probe, role: "file.mnd.metadataDump",
                                 level: .info,
                                 "metadata_protobuf_head256",
                                 ["uri": uri,
                                  "bytes": bytes,
                                  "head256": wideHead])
                }
                gate.resume(cont, returning: .init(
                    type: type, typeName: typeName, bytes: bytes,
                    ok: true, errorMessage: nil,
                    durationMs: ms, headHex: head,
                    transport: "commandsImpl"))
            }
            // Invoke via NSInvocation-style perform — three args via boxed
            // selector. Swift's `perform(_:with:with:)` only supports 2 args,
            // so use a typed function pointer cast.
            typealias IMP3 = @convention(c) (NSObject, Selector, NSString, UInt, @convention(block) (NSError?, NSData?) -> Void) -> Void
            let imp = cmd.method(for: sel)
            let function = unsafeBitCast(imp, to: IMP3.self)
            function(cmd, sel, uri as NSString, UInt(type), block)
        }
    }

    private struct ThumbnailProbeResult {
        let bytes: Int?
        let error: String?
        let ms: Int?
    }

    private func probeFileThumbnail(uri: String) async -> ThumbnailProbeResult {
        let started = Date()
        let http = INSCameraHTTPManager.socket()
        return await withCheckedContinuation { (cont: CheckedContinuation<ThumbnailProbeResult, Never>) in
            let gate = ProbeGate<ThumbnailProbeResult>()
            let timeout = DispatchWorkItem {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                gate.resume(cont, returning: .init(
                    bytes: nil, error: "timed out after 8s", ms: ms))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)

            let task = http.fetchVideoThumbnail(withURI: uri) { error, data in
                timeout.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let error {
                    InstaLog.log(.probe, role: "file.thumb", level: .warn,
                                 "thumbnail_failed",
                                 ["uri": uri, "ms": ms, "error": error.localizedDescription])
                    gate.resume(cont, returning: .init(
                        bytes: nil, error: error.localizedDescription, ms: ms))
                    return
                }
                let bytes = data?.count ?? 0
                InstaLog.log(.probe, role: "file.thumb", level: .info,
                             "thumbnail_ok",
                             ["uri": uri, "ms": ms, "bytes": bytes])
                gate.resume(cont, returning: .init(bytes: bytes, error: nil, ms: ms))
            }
            if task == nil {
                timeout.cancel()
                gate.resume(cont, returning: .init(
                    bytes: nil, error: "task=nil",
                    ms: Int(Date().timeIntervalSince(started) * 1000)))
            }
        }
    }

    // MARK: - Summary

    private func emitSummary(
        cameraUUID: String,
        cameraName: String?,
        startedAtIso: String,
        storage: Insta360MetadataProbe.StorageReport?,
        listings: [Insta360MetadataProbe.ListingReport],
        perFile: [Insta360MetadataProbe.PerFileReport],
        warnings: [String]
    ) {
        InstaLog.log(.probe, role: "summary", level: .state,
                     "summary_header",
                     ["uuid": cameraUUID,
                      "name": cameraName ?? "nil",
                      "startedAt": startedAtIso])

        if let s = storage {
            InstaLog.log(.probe, role: "summary", level: .state,
                         "summary_storage",
                         ["freeGB": String(format: "%.2f", Double(s.freeBytes) / 1_073_741_824.0),
                          "totalGB": String(format: "%.2f", Double(s.totalBytes) / 1_073_741_824.0),
                          "usedGB": String(format: "%.2f", Double(s.usedBytes) / 1_073_741_824.0),
                          "cardState": s.cardState,
                          "cardLocation": s.cardLocation])
        } else {
            InstaLog.log(.probe, role: "summary", level: .warn,
                         "summary_storage_unavailable", [:])
        }

        for listing in listings {
            InstaLog.log(.probe, role: "summary", level: listing.ok ? .state : .warn,
                         "summary_listing",
                         ["api": listing.api,
                          "ok": listing.ok,
                          "ms": listing.durationMs,
                          "fileCount": listing.fileCount ?? -1,
                          "error": listing.errorMessage ?? "nil",
                          "extras": listing.extras.keys.sorted().map { "\($0)=\(listing.extras[$0]!)" }.joined(separator: ",")])
        }

        for file in perFile {
            let okTypes = file.mnd.filter { $0.ok }.map { "\($0.typeName):\($0.bytes ?? 0)B" }
            let failTypes = file.mnd.filter { !$0.ok }.map { $0.typeName }
            InstaLog.log(.probe, role: "summary", level: .state,
                         "summary_per_file",
                         ["uri": file.uri,
                          "thumbBytes": file.httpThumbnailBytes ?? -1,
                          "thumbMs": file.httpThumbnailMs ?? -1,
                          "mndOk": okTypes,
                          "mndFail": failTypes])
        }

        if !warnings.isEmpty {
            InstaLog.log(.probe, role: "summary", level: .warn,
                         "summary_warnings",
                         ["count": warnings.count,
                          "head": warnings.prefix(5).joined(separator: " | ")])
        }
    }

    // MARK: - Utility

    private static func headHex(_ data: Data, count: Int) -> String {
        let n = min(count, data.count)
        guard n > 0 else { return "" }
        return data.prefix(n).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
