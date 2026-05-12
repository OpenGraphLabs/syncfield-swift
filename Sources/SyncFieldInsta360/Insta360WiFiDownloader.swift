import Foundation
import Network

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK
#endif

#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// Automatically switches the iPhone onto the Insta360 camera's WiFi AP,
/// downloads the requested clip via the Insta360 SDK HTTP socket, then
/// removes the hotspot configuration so the previous WiFi is restored.
///
/// Ported from egonaut's `Insta360WiFiTransferManager.swift` with:
/// - Automatic `NEHotspotConfiguration` apply before reachability check
/// - Reachability retry count reduced from 15 to 3 (AP IP is ready ~1-2 s
///   after `apply` completes)
/// - `defer` block for belt-and-suspenders cleanup (socket shutdown +
///   hotspot configuration removal) on both success and failure paths
public final class Insta360WiFiDownloader: @unchecked Sendable {
    private let cameraHost = "192.168.42.1"
    private let cameraPort: UInt16 = 6666

    public init() {}

    public static func isLikelyCameraHotspotSSID(_ ssid: String) -> Bool {
        let normalized = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return normalized.uppercased().hasSuffix(".OSC")
    }

    #if canImport(INSCameraServiceSDK) && canImport(NetworkExtension)

    /// Atomically: join camera AP → probe reachability → open SDK socket →
    /// download file with progress callbacks → restore previous WiFi.
    ///
    /// - Parameters:
    ///   - remoteFileURI: Camera-side URI returned by `stopRemoteRecording()`.
    ///   - destination:   Local URL to write the mp4 into.
    ///   - ssid:          Camera AP SSID (from `Insta360BLEController.wifiCredentials()`).
    ///   - passphrase:    Camera AP passphrase (same source).
    ///   - progress:      Fraction-completed callback on an unspecified queue.
    /// - Returns: Size in bytes of the downloaded file.
    public func download(remoteFileURI: String,
                         to destination: URL,
                         ssid: String,
                         passphrase: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        try await applyHotspot(ssid: ssid, passphrase: passphrase)

        var downloadError: Error?
        var bytes: Int64 = 0
        do {
            // 8 attempts × 1 s = 8 s. The AP's DHCP-assigned IP appears
            // 1–5 s after `NEHotspotConfiguration.apply` resolves on most
            // hardware, and during that window every probe returns false;
            // the previous 3-attempt budget was fragile when iOS took
            // longer to swing the default route.
            try await waitForReachability(attempts: 8)

            NSLog("[WiFiDownloader] Camera reachable — connecting SDK socket")
            INSCameraManager.socket().setup()
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 s for socket init
            INSCameraManager.socket().commandsImpl.sendHeartbeats(with: nil)

            bytes = try await fetchResource(remoteFileURI: remoteFileURI,
                                             destination: destination,
                                             progress: progress)
        } catch {
            downloadError = error
        }

        // Explicit cleanup (replacing the previous `defer` block).
        // `defer` can't await, which mattered because iOS needs a beat
        // after `removeConfiguration` to actually disassociate from the
        // camera AP and auto-rejoin a saved home Wi-Fi. Without the wait
        // the device stayed on `GO 3S *.OSC` until the user manually
        // switched networks.
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        INSCameraManager.socket().shutdown()
        NSLog("[WiFiDownloader] Hotspot config removed + SDK socket shut down (ssid=\(ssid))")
        try? await waitForSystemWiFiRestore(away: cameraHost)

        if let error = downloadError { throw error }
        return bytes
    }

    /// One pending file to fetch as part of a batch on the same camera AP.
    /// Carries the episode directory so the caller's progress callback can
    /// tag events per-episode (the batch-collect UI fans out across multiple
    /// episodes that happen to share a camera).
    public struct BatchItem: Sendable {
        public let episodeDir: URL
        public let streamId: String
        public let remoteFileURI: String
        public let destination: URL
        public let bleAckMonotonicNs: UInt64

        public init(episodeDir: URL, streamId: String,
                    remoteFileURI: String, destination: URL,
                    bleAckMonotonicNs: UInt64) {
            self.episodeDir = episodeDir
            self.streamId = streamId
            self.remoteFileURI = remoteFileURI
            self.destination = destination
            self.bleAckMonotonicNs = bleAckMonotonicNs
        }
    }

    public struct BatchResult: Sendable {
        public let item: BatchItem
        public let success: Bool
        public let error: String?
    }

    /// Download a batch of files from a single camera AP. Applies the
    /// hotspot configuration once, waits for the AP to come up, then
    /// fetches every item sequentially over the same SDK socket before
    /// tearing down. This is ~3–5× faster than calling `download` once per
    /// file because each call pays the 1–5 s `apply + waitForReachability`
    /// cost for the same camera.
    ///
    /// Batch-level semantics:
    ///   - If `applyHotspot` or `waitForReachability` fails, every item is
    ///     reported failed with the same error (we never got on the AP).
    ///   - Individual `fetchResource` failures mark that item failed but the
    ///     rest of the batch continues — disk-full or camera-side error on
    ///     one file shouldn't abort the others.
    ///   - On return, the hotspot config is removed and the SDK socket is
    ///     shut down. Final home-Wi-Fi restore is the CALLER'S job (via
    ///     `finalizeWiFiRestore`) so per-camera teardown stays fast.
    public func downloadBatch(
        ssid: String,
        passphrase: String,
        items: [BatchItem],
        onItemStart: @escaping @Sendable (BatchItem) -> Void,
        progress: @escaping @Sendable (BatchItem, Double) -> Void
    ) async -> [BatchResult] {
        if items.isEmpty { return [] }

        do {
            try await applyHotspot(ssid: ssid, passphrase: passphrase)
            try await waitForReachability(attempts: 8)
        } catch {
            NSLog("[WiFiDownloader] downloadBatch failed to join \(ssid): \(error.localizedDescription)")
            let msg = error.localizedDescription
            var results: [BatchResult] = []
            for item in items {
                results.append(BatchResult(item: item, success: false, error: msg))
            }
            // Still try to clean up — `apply` may have half-succeeded.
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            return results
        }

        NSLog("[WiFiDownloader] downloadBatch: on \(ssid), \(items.count) file(s) queued")

        // IMPORTANT: `INSCameraHTTPManager` does NOT support back-to-back
        // `fetchResource` calls on the same socket session. The first fetch
        // completes cleanly; the second one silently hangs forever because
        // the SDK's internal HTTP manager state doesn't reset between
        // transfers. The working single-file `download()` path calls
        // `setup() → fetchResource → shutdown()` per file, and we must do
        // the same here — except we keep the hotspot (NEHotspotConfiguration)
        // applied across the whole batch so iOS stays on the camera AP.
        //
        // Socket setup/teardown per file costs ~1 s (500 ms init + 500 ms
        // sleep) but avoids the silent stall that was only pulling the first
        // file of each camera's batch.

        var results: [BatchResult] = []
        for (idx, item) in items.enumerated() {
            // Fresh SDK socket per file (SDK doesn't support back-to-back
            // fetchResource on one socket). First file sleeps 300 ms after
            // setup to let the socket init; subsequent files only need 150 ms
            // because the AP's already warm. Previously we slept 500 ms
            // blindly — saved ~1–2 s across a typical batch.
            INSCameraManager.socket().setup()
            try? await Task.sleep(nanoseconds: idx == 0 ? 300_000_000 : 150_000_000)
            INSCameraManager.socket().commandsImpl.sendHeartbeats(with: nil)

            // Signal "this item is the one actively downloading now" so the
            // UI can move the progress bar to it. Queued siblings stay in
            // their prior phase (pairing) until their turn comes up.
            onItemStart(item)
            do {
                try FileManager.default.createDirectory(
                    at: item.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)

                let throttle = ProgressThrottle(minIntervalNs: 250_000_000)
                // NOTE: camera-side transcode (transcodeAndFetch) is currently
                // disabled — the SDK shipping with this app version doesn't
                // expose `INSEditProject.toPbData` and `fetchVideoList` returns
                // empty for the Go 3S, so the transcode path can't run.
                // Documented in the spec at §9 "Risks" — fallback to raw
                // fetchResource. For 1080p flat recordings the camera-side
                // file is already a small standard mp4 (~5 MB/s of recording
                // = a few-MB-per-second transfer), so the speed cost is
                // marginal vs. the transcode path. Switch back to transcode
                // when (a) the SDK exposes a working serialization API, or
                // (b) we move to high-bitrate 5K360 recording where raw
                // .insv files are 5–10× larger.
                _ = try await fetchResourceWithTimeout(
                    remoteFileURI: item.remoteFileURI,
                    destination: item.destination,
                    timeoutSeconds: 600,
                    progress: { f in
                        if throttle.shouldEmit() {
                            progress(item, f)
                        }
                    })
                // Always emit a 100% tick before signalling success so the
                // UI hits a clean "done" state even if the throttle dropped
                // the final fractional update.
                progress(item, 1.0)
                results.append(BatchResult(item: item, success: true, error: nil))
            } catch {
                NSLog("[WiFiDownloader] downloadBatch item \(item.streamId) failed: \(error.localizedDescription)")
                results.append(BatchResult(
                    item: item, success: false, error: error.localizedDescription))
            }

            // Tear down the SDK socket. No sleep here — the next `setup()`
            // opens a fresh socket which gives the SDK its own init window;
            // the earlier "300 ms wait to let teardown complete" turned out
            // to be defensive padding we can drop.
            INSCameraManager.socket().shutdown()
        }

        // Drop the hotspot config. Don't block on `waitForSystemWiFiRestore`
        // between cameras — the NEXT camera's `applyHotspot` overrides
        // whichever AP iOS is still attached to, and waiting here just
        // added a flat 3 s between cameras. The final camera's teardown
        // is handled by `finalizeWiFiRestore` at the collect loop's end.
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        return results
    }

    /// Per-file timeout wrapper around `fetchResource` so one stuck HTTP
    /// fetch doesn't hang the entire batch.
    ///
    /// **Critical:** the `cancelAll()` call MUST happen synchronously
    /// before the closure ends. The previous version had it in `defer` AND
    /// drained remaining tasks via `while (try? await group.next()) != nil`
    /// — which blocked for the full `timeoutSeconds` (600 s = 10 min!)
    /// after a successful download because the sleep task ran to its
    /// natural deadline before the defer-registered cancel ever fired.
    /// That was the root cause of the "Download complete → 10 min silence"
    /// hang users observed between cameras.
    private func fetchResourceWithTimeout(
        remoteFileURI: String,
        destination: URL,
        timeoutSeconds: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            group.addTask {
                try await self.fetchResource(
                    remoteFileURI: remoteFileURI,
                    destination: destination,
                    progress: progress)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw Insta360Error.downloadFailed("fetch timed out after \(timeoutSeconds)s")
            }
            let result = try await group.next()!
            // Cancel the still-sleeping timeout task BEFORE returning so
            // the group's auto-drain at scope exit doesn't wait on it.
            group.cancelAll()
            return result
        }
    }

    // MARK: - Camera-side transcode (fast collect path)
    //
    // See spec: docs/superpowers/specs/2026-04-26-fast-insta360-collect-design.md
    //
    // The plain `fetchResource` path above pulls the raw `.insv` file from the
    // camera, which is 5–10× larger than what we actually need for downstream
    // training (1080p mp4). This section instructs the camera to transcode the
    // clip on-device first (using its hardware H.264 encoder), then downloads
    // the much smaller resulting mp4. Target: 30–60 s for a 3-camera 15 s clip
    // batch, vs the 15–20 min observed with raw fetch.
    //
    // The implementation has Phase 0 assumptions baked in (marked PHASE_0).
    // First hardware run validates them via the extensive NSLog trail; if the
    // camera doesn't behave as expected, the logs pinpoint which assumption to
    // revisit.

    #if SYNCFIELD_INSTA360_TRANSCODE

    /// Build an `INSEditProject` describing a single-clip export at the
    /// requested resolution / fps / bitrate. The project is uploaded to the
    /// camera which then runs its hardware H.264 encoder against the source
    /// clip whose camera-side path is passed as the `filePath:` parameter to
    /// `uploadEditDataWithData`.
    private func buildExportProject(options: Insta360TranscodeOptions) -> INSEditProject {
        // Use raw NS_ENUM values directly — Swift's case-name mangling for
        // these prefix-heavy Insta360 enums is unpredictable, so referring to
        // the integer rawValues avoids guessing.
        //   INSEditVideoTypeNormalmp4 = 0   (INSEditOptions.h)
        //   INSEditCodecIdH264        = 27
        //   INSEditChannelLayoutStereo= 2
        //   INSEditProjectSegmentTypeEdit = 0
        //   INSEditDataSourceIos      = 2
        let videoEncode = INSEditExportInfoVideoEncodeOption()
        videoEncode.width = options.width
        videoEncode.height = options.height
        videoEncode.fps = options.fps
        videoEncode.bitrate = options.bitrate
        videoEncode.videoType = INSEditVideoType(rawValue: 0)!  // Normalmp4
        let codec = INSEditEnumCodecIdValue()
        codec.value = INSEditCodecId(rawValue: 27)!             // H264
        videoEncode.codecid = codec

        let audioEncode = INSEditExportInfoAudioEncodeOption()
        audioEncode.audioBitrate = 128_000
        audioEncode.sampleRate = 48_000
        audioEncode.channelLayout = INSEditChannelLayout(rawValue: 2)!  // Stereo

        let exportInfo = INSEditExportInformation()
        exportInfo.videoEncodeOption = videoEncode
        exportInfo.audioEncodeOption = audioEncode
        // Skip: denoiseSettings, waterMark, edgeInfo, clearColor,
        // otherInfoOption, logo. nil/off matches official app's minimal
        // "워터마크 꺼짐" export preset.

        let segment = INSEditProjectSegment()
        segment.id_p = UUID().uuidString
        // PHASE_0: dataType=Edit (rawValue 0). If transcode doesn't trigger,
        // try Snap (rawValue 1) on next iteration — that enum case literally
        // means "render a snapshot/output of the segment".
        segment.dataType = INSEditProjectSegmentType(rawValue: 0)!  // Edit
        segment.clipindex = 0

        let project = INSEditProject()
        project.version = 1
        project.source = INSEditDataSource(rawValue: 2)!  // iOS
        project.projectName = "egonaut_collect_\(UUID().uuidString.prefix(8))"
        // Obj-C lightweight generic NSMutableArray<INSEditProjectSegment*> isn't
        // a real Swift generic — set via KVC to bypass the spurious type check.
        let segments = NSMutableArray()
        segments.add(segment)
        (project as NSObject).setValue(segments, forKey: "segmentsArray")
        return project
    }

    /// Serialize an `INSEditProject` to its protobuf wire format.
    /// `INSEditProject` doesn't expose `toPbData` in the public header, but
    /// every protobuf-backed object in this SDK family follows the same
    /// convention (verified in `INSProxyVideoInfo.h` which DOES expose it
    /// publicly). We invoke via Obj-C runtime; if the runtime check fails,
    /// the spike has uncovered a wrong assumption.
    private func serializeProject(_ project: INSEditProject) throws -> Data {
        let sel = NSSelectorFromString("toPbData")
        let obj = project as AnyObject
        guard obj.responds(to: sel) else {
            throw Insta360Error.transcodeFailed(
                "INSEditProject does not respond to toPbData (PHASE_0 assumption violated; serialization API differs from INSProxyVideoInfo)")
        }
        guard let unmanaged = obj.perform(sel) else {
            throw Insta360Error.transcodeFailed("toPbData returned nil")
        }
        let value = unmanaged.takeUnretainedValue()
        guard let nsData = value as? NSData else {
            throw Insta360Error.transcodeFailed(
                "toPbData returned non-NSData type: \(type(of: value))")
        }
        return nsData as Data
    }

    /// Snapshot every video URI currently visible to the camera HTTP API.
    /// Used as a before/after diff to discover which URI the transcoded mp4
    /// landed at (since `uploadEditDataWithData`'s completion block reports
    /// no output URI directly).
    private func fetchVideoURIs() async throws -> Set<String> {
        let http = INSCameraHTTPManager.socket()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Set<String>, Error>) in
            let task = http.fetchVideoList(completion: { error, list in
                if let error = error {
                    cont.resume(throwing: Insta360Error.transcodeFailed(
                        "fetchVideoList failed: \(error.localizedDescription)"))
                    return
                }
                var set = Set<String>()
                if let list = list as? [Any] {
                    for item in list {
                        let obj = item as AnyObject
                        if obj.responds(to: NSSelectorFromString("uri")),
                           let uri = obj.value(forKey: "uri") as? String,
                           !uri.isEmpty {
                            set.insert(uri)
                        }
                    }
                }
                cont.resume(returning: set)
            })
            if task == nil {
                cont.resume(throwing: Insta360Error.transcodeFailed(
                    "fetchVideoList returned nil task"))
            }
        }
    }

    /// Locate the transcoded output URI by diffing the video list before and
    /// after the upload. Falls back to a predictable `.insv → .mp4` rule.
    private func discoverTranscodedURI(
        sourceURI: String,
        preList: Set<String>
    ) async throws -> String {
        let postList = try await fetchVideoURIs()
        let newURIs = postList.subtracting(preList)
        NSLog("[WiFiDownloader.transcode] discoverURI: pre=\(preList.count) post=\(postList.count) new=\(newURIs.count)")
        for uri in newURIs {
            NSLog("[WiFiDownloader.transcode] discoverURI: new candidate: \(uri)")
        }

        // Primary: list diff. If exactly one new file appeared, that's our output.
        if let outputURI = newURIs.first {
            if newURIs.count > 1 {
                // Prefer mp4 if multiple. Otherwise just take the first.
                let mp4Match = newURIs.first(where: { $0.lowercased().hasSuffix(".mp4") })
                let pick = mp4Match ?? outputURI
                NSLog("[WiFiDownloader.transcode] discoverURI: multiple new URIs; picked \(pick)")
                return pick
            }
            return outputURI
        }

        // Fallback 1: predictable rule (.insv → .mp4 sibling).
        if sourceURI.hasSuffix(".insv") {
            let candidate = String(sourceURI.dropLast(5)) + ".mp4"
            NSLog("[WiFiDownloader.transcode] discoverURI: no list-diff hit; trying predictable .insv→.mp4: \(candidate)")
            // Verify the candidate is actually reachable before returning it.
            let http = INSCameraHTTPManager.socket()
            let reachable: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let task = http.headResource(withURI: candidate, completion: { error in
                    cont.resume(returning: error == nil)
                })
                if task == nil { cont.resume(returning: false) }
            }
            if reachable {
                NSLog("[WiFiDownloader.transcode] discoverURI: predictable candidate is reachable")
                return candidate
            }
            NSLog("[WiFiDownloader.transcode] discoverURI: predictable candidate NOT reachable")
        }

        throw Insta360Error.transcodeFailed(
            "no transcoded output found (sourceURI=\(sourceURI), preList=\(preList.count), postList=\(postList.count); PHASE_0 assumption — uploadEditDataWithData triggers transcode — may be wrong)")
    }

    /// PHASE_0 ASSUMPTION: `uploadEditDataWithData(data:filePath:...)`'s
    /// `filePath:` parameter is the camera-side path of the source clip
    /// (i.e. the URI returned by stopCapture's `videoInfo.uri`). The camera
    /// reads the project's export options from `data` and writes the
    /// transcoded output somewhere on its storage. Completion fires when
    /// transcode is done.
    ///
    /// If first-run logs show completion fires too quickly (<1 s) and no new
    /// file appears in the post-list, this assumption is wrong and we'd need
    /// to either (a) poll camera status separately, or (b) use a different
    /// API to trigger the actual render step.
    private func uploadEditDataAndWait(
        project: INSEditProject,
        cameraSourceFilePath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let projectData = try serializeProject(project)
        NSLog("[WiFiDownloader.transcode] uploadEditData filePath=\(cameraSourceFilePath) projectBytes=\(projectData.count)")

        let http = INSCameraHTTPManager.socket()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = http.uploadEditData(
                with: projectData,
                filePath: cameraSourceFilePath,
                progress: { p in
                    progress(p.fractionCompleted)
                },
                completion: { error in
                    if let error = error {
                        NSLog("[WiFiDownloader.transcode] uploadEditData FAILED: \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.transcodeFailed(
                            "uploadEditData: \(error.localizedDescription)"))
                        return
                    }
                    NSLog("[WiFiDownloader.transcode] uploadEditData completion fired (assuming camera transcode done)")
                    cont.resume()
                })
            if task == nil {
                cont.resume(throwing: Insta360Error.transcodeFailed(
                    "uploadEditData returned nil task"))
            }
        }
    }

    /// End-to-end: snapshot pre-list → upload edit project (camera transcodes)
    /// → discover output URI → fetch the transcoded mp4. Replaces the raw
    /// `.insv` fetchResource path used in `downloadBatch`.
    public func transcodeAndFetch(
        sourceURI: String,
        destination: URL,
        options: Insta360TranscodeOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let startedAt = Date()
        NSLog("[WiFiDownloader.transcode] BEGIN sourceURI=\(sourceURI) → \(destination.lastPathComponent) preset=\(options.width)x\(options.height)@\(options.fps)fps \(options.bitrate)bps")

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // 1. Pre-snapshot.
        let preList: Set<String>
        do {
            preList = try await fetchVideoURIs()
        } catch {
            NSLog("[WiFiDownloader.transcode] preList fetch failed (continuing with empty set): \(error.localizedDescription)")
            preList = Set<String>()
        }

        // 2. Build + upload project (camera transcodes).
        let project = buildExportProject(options: options)
        let uploadStart = Date()
        try await uploadEditDataAndWait(
            project: project,
            cameraSourceFilePath: sourceURI,
            progress: { f in
                // Map upload-byte progress to 0.0–0.5 of overall progress.
                // The actual transcode work is invisible (no separate progress
                // signal); both are reported as the same upload phase.
                progress(f * 0.5)
            })
        let uploadAndTranscodeDuration = Date().timeIntervalSince(uploadStart)
        NSLog("[WiFiDownloader.transcode] upload+transcode total: \(uploadAndTranscodeDuration)s")

        // 3. Discover transcoded URI.
        let outputURI = try await discoverTranscodedURI(sourceURI: sourceURI, preList: preList)
        NSLog("[WiFiDownloader.transcode] outputURI=\(outputURI)")

        // 4. Fetch the (small) transcoded mp4. Reuse the existing fetchResource
        //    helper — same SDK path, same socket, but a much smaller payload.
        let fetchStart = Date()
        let bytes = try await fetchResource(
            remoteFileURI: outputURI,
            destination: destination,
            progress: { f in
                progress(0.5 + f * 0.5)
            })
        let fetchDuration = Date().timeIntervalSince(fetchStart)

        let totalDuration = Date().timeIntervalSince(startedAt)
        NSLog("[WiFiDownloader.transcode] DONE bytes=\(bytes) upload+transcode=\(String(format: "%.2f", uploadAndTranscodeDuration))s fetch=\(String(format: "%.2f", fetchDuration))s total=\(String(format: "%.2f", totalDuration))s")
        return bytes
    }

    /// Per-file timeout wrapper around `transcodeAndFetch`. Tighter timeout
    /// than the raw-fetch path because per-camera target is 10–25 s; if it
    /// takes >120 s, something's wrong and the batch retry is more useful
    /// than waiting longer. See `fetchResourceWithTimeout` for why
    /// `cancelAll()` must be explicit and synchronous.
    private func transcodeAndFetchWithTimeout(
        sourceURI: String,
        destination: URL,
        options: Insta360TranscodeOptions,
        timeoutSeconds: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            group.addTask {
                try await self.transcodeAndFetch(
                    sourceURI: sourceURI,
                    destination: destination,
                    options: options,
                    progress: progress)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw Insta360Error.transcodeFailed("transcode+fetch timed out after \(timeoutSeconds)s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    #else

    public func transcodeAndFetch(
        sourceURI: String,
        destination: URL,
        options: Insta360TranscodeOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        progress(0)
        throw Insta360Error.transcodeFailed(
            "camera-side transcode is not enabled in this SyncFieldInsta360 build")
    }

    #endif

    /// `ProgressThrottle` equivalent local to this file. Nested type so the
    /// batch path doesn't need to reach into SyncFieldBridgeModule's private
    /// helper.
    private final class ProgressThrottle: @unchecked Sendable {
        private let minIntervalNs: UInt64
        private var lastEmitNs: UInt64 = 0
        private let lock = NSLock()
        init(minIntervalNs: UInt64) { self.minIntervalNs = minIntervalNs }
        func shouldEmit() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastEmitNs < minIntervalNs { return false }
            lastEmitNs = now
            return true
        }
    }

    /// Poll until the camera AP is no longer reachable — a practical
    /// signal that iOS has disassociated. Capped short because between
    /// cameras we don't need full home-Wi-Fi rejoin; the next camera's
    /// `applyHotspot` overrides immediately. The long-form "restore to
    /// the user's original Wi-Fi" wait is in `finalizeWiFiRestore`,
    /// invoked once after the whole collect loop completes.
    private func waitForSystemWiFiRestore(away cameraHost: String) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !(await isHostReachable(host: cameraHost, port: cameraPort)) {
                NSLog("[WiFiDownloader] Camera AP no longer reachable — network restored")
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
        }
        NSLog("[WiFiDownloader] Gave up waiting for Wi-Fi restore after 3 s")
    }

    /// Finalisation no-op for the collect promise.
    ///
    /// iOS app sandbox does NOT let us programmatically switch back to a
    /// user-saved WiFi network — only `NEHotspotConfiguration` with a
    /// known SSID/passphrase, which we don't have for the user's home
    /// network. After `removeAllHotspotConfigurations()` clears our
    /// camera-AP joins, iOS handles the next hop by itself:
    ///   - if a saved WiFi is in range → iOS auto-roams to it (5–15 s)
    ///   - if cellular only → iOS falls through to LTE
    ///   - if neither → iPhone has no internet until user enables one
    ///
    /// The previous 15 s polling loop tried to confirm restoration via
    /// `isHostReachable("1.1.1.1")` + camera AP unreachable, but iOS'
    /// internal NECP state (`nw_path_necp_check_for_updates Failed to
    /// copy updated result (22)` in the syslog) doesn't reliably
    /// converge in that window even when the network IS up — and on
    /// cellular-only setups the polling can flake even with perfectly
    /// good service. Blocking the collect promise on a check that's
    /// neither reliable NOR actionable just left users staring at a
    /// "Restoring WiFi…" spinner that timed out 100 % of the time on
    /// cellular.
    ///
    /// Now: caller is expected to invoke `removeAllHotspotConfigurations()`
    /// (the actionable cleanup), then resolve the collect promise. This
    /// method is kept as a labelled no-op so existing call sites
    /// continue to compile; can be removed in a follow-up.
    public func finalizeWiFiRestore() async {
        NSLog("[WiFiDownloader] finalizeWiFiRestore — no-op (hotspot configs cleared; iOS will roam in background)")
    }

    /// Sweep away any lingering `NEHotspotConfiguration` entries our app has
    /// installed. Called at the end of collect as a belt-and-suspenders so
    /// that a failed teardown mid-loop doesn't leave a stale config attached
    /// to the phone.
    ///
    /// **iOS sandbox limitation:** `removeConfiguration(forSSID:)` removes
    /// the saved config but in iOS 15+ does NOT reliably force the iPhone
    /// to disassociate from an actively-joined camera AP. We have no
    /// public API to:
    ///   - force disconnect from a specific SSID
    ///   - toggle WiFi off/on
    ///   - join a different (user-saved) SSID without knowing its passphrase
    /// So if iOS sticks on the camera AP after this sweep, the user has to
    /// either toggle WiFi manually in iOS Settings, or wait until the
    /// camera goes out of range. Internet still works via cellular while
    /// WiFi is "stuck" on the AP — only the indicator is misleading.
    /// We make 2 sweeps with a brief settle window in between to give
    /// iOS the best chance of honouring the removal.
    public func removeAllHotspotConfigurations() async {
        for sweep in 1...2 {
            let ssids: [String] = await withCheckedContinuation { cont in
                NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
                    cont.resume(returning: ssids)
                }
            }
            if ssids.isEmpty {
                if sweep == 1 {
                    NSLog("[WiFiDownloader] removeAllHotspotConfigurations sweep \(sweep): nothing to remove (joinOnce auto-cleanup likely already ran)")
                }
                return
            }
            for ssid in ssids {
                NSLog("[WiFiDownloader] removeAllHotspotConfigurations sweep \(sweep): removing SSID=\(ssid)")
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
            if sweep == 1 {
                // Give iOS ~500 ms to process the first round before
                // re-checking. Accumulated app installations sometimes
                // require two passes to clear the list completely.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Remove only Insta360 camera AP configurations, preserving upload Wi-Fi
    /// profiles the host app may also manage through NEHotspotConfiguration.
    public func removeCameraHotspotConfigurations() async {
        for sweep in 1...2 {
            let ssids: [String] = await withCheckedContinuation { cont in
                NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
                    cont.resume(returning: ssids)
                }
            }
            let cameraSSIDs = ssids.filter(Self.isLikelyCameraHotspotSSID)
            if cameraSSIDs.isEmpty {
                if sweep == 1 {
                    NSLog("[WiFiDownloader] removeCameraHotspotConfigurations: no camera SSIDs to remove")
                }
                return
            }
            for ssid in cameraSSIDs {
                NSLog("[WiFiDownloader] removeCameraHotspotConfigurations sweep \(sweep): removing SSID=\(ssid)")
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
            if sweep == 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Hotspot

    private func applyHotspot(ssid: String, passphrase: String) async throws {
        // Two attempts. `NEHotspotConfiguration.apply` occasionally fails
        // with `internal` / `system` error codes when iOS is still in the
        // middle of releasing the previous camera's config; a single
        // retry after a short delay almost always succeeds.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await applyHotspotOnce(ssid: ssid, passphrase: passphrase)
                if attempt > 1 {
                    NSLog("[WiFiDownloader] applyHotspot succeeded on attempt \(attempt)")
                }
                return
            } catch {
                lastError = error
                NSLog("[WiFiDownloader] applyHotspot attempt \(attempt)/2 failed: \(error.localizedDescription)")
                if attempt < 2 {
                    // Pre-clean: iOS may still have the previous SSID's
                    // configuration active — sweeping it lets the next
                    // apply start fresh.
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        throw lastError ?? Insta360Error.hotspotApplyFailed("apply failed after 2 attempts")
    }

    private func applyHotspotOnce(ssid: String, passphrase: String) async throws {
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        config.joinOnce = true

        let sendUptimeNs = DispatchTime.now().uptimeNanoseconds
        NSLog("[WiFiDownloader.timing] applyHotspot SEND ssid=\(ssid)")

        // Wrap in a 30-second timeout. NEHotspotConfiguration.apply has no
        // built-in deadline; if iOS' WiFi state machine deadlocks (most
        // commonly when we removeConfiguration for camera N and apply for
        // camera N+1 in quick succession), the completion never fires and
        // the entire collect hangs forever. 30 s is generous — typical
        // apply is ~1-3 s; up to ~10 s when iOS is mid-roaming. Anything
        // longer is genuinely stuck.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    NEHotspotConfigurationManager.shared.apply(config) { error in
                        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - sendUptimeNs) / 1_000_000.0
                        if let ns = error as NSError? {
                            // alreadyAssociated means the device is already on this SSID — not an error.
                            if ns.domain == NEHotspotConfigurationErrorDomain,
                               ns.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                                NSLog("[WiFiDownloader.timing] applyHotspot ALREADY-ASSOCIATED ssid=\(ssid) elapsedMs=\(String(format: "%.0f", elapsedMs))")
                                cont.resume()
                                return
                            }
                            NSLog("[WiFiDownloader.timing] applyHotspot FAILED ssid=\(ssid) elapsedMs=\(String(format: "%.0f", elapsedMs)): \(ns.localizedDescription)")
                            cont.resume(throwing: Insta360Error.hotspotApplyFailed(ns.localizedDescription))
                            return
                        }
                        NSLog("[WiFiDownloader.timing] applyHotspot OK ssid=\(ssid) elapsedMs=\(String(format: "%.0f", elapsedMs))")
                        cont.resume()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
                NSLog("[WiFiDownloader.timing] applyHotspot TIMEOUT ssid=\(ssid) — iOS WiFi state likely stuck")
                throw Insta360Error.hotspotApplyFailed("apply timed out after 30 s (iOS WiFi state stuck)")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    // MARK: - Reachability

    private func waitForReachability(attempts: Int) async throws {
        NSLog("[WiFiDownloader] Probing \(cameraHost):\(cameraPort) (\(attempts) attempts)...")
        for attempt in 1...attempts {
            if await isHostReachable(host: cameraHost, port: cameraPort) {
                NSLog("[WiFiDownloader] Camera reachable after \(attempt) attempt(s)")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Insta360Error.cameraNotReachable
    }

    private func isHostReachable(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "syncfield.insta360.reachability")
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp)
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true; conn.cancel(); cont.resume(returning: true)
                case .failed, .cancelled:
                    done = true; conn.cancel(); cont.resume(returning: false)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            // Per-attempt timeout: 3 s (reachability probe should resolve quickly
            // once the IP is up; we don't want to block the full 1-s retry budget).
            queue.asyncAfter(deadline: .now() + 3) {
                guard !done else { return }
                done = true; conn.cancel(); cont.resume(returning: false)
            }
        }
    }

    // MARK: - Download

    private func fetchResource(remoteFileURI: String,
                               destination: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        NSLog("[WiFiDownloader] Downloading \(remoteFileURI) → \(destination.path)")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let http = INSCameraHTTPManager.socket()
        // Capture throughput per file so callers (and future tuning work)
        // can see whether the bottleneck is the camera radio, the SDK's
        // HTTP layer, or our own surrounding overhead. Logs land under
        // `[WiFiDownloader.throughput]` for easy grep.
        let startUptimeNs = DispatchTime.now().uptimeNanoseconds
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            let task = http.fetchResource(
                withURI: remoteFileURI,
                toLocalFile: destination,
                progress: { p in
                    if let p = p { progress(p.fractionCompleted) }
                },
                completion: { error in
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startUptimeNs) / 1_000_000.0
                    if let error = error {
                        NSLog("[WiFiDownloader.throughput] FAILED uri=\(remoteFileURI) elapsedMs=\(String(format: "%.0f", elapsedMs)) error=\(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.downloadFailed(error.localizedDescription))
                        return
                    }
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: destination.path)[.size]) as? Int64 ?? 0
                    let mb = Double(size) / 1_048_576.0
                    let mbps = elapsedMs > 0 ? (mb / (elapsedMs / 1000.0)) : 0
                    NSLog("[WiFiDownloader.throughput] OK uri=\(remoteFileURI) bytes=\(size) sizeMB=\(String(format: "%.2f", mb)) elapsedMs=\(String(format: "%.0f", elapsedMs)) throughputMBps=\(String(format: "%.2f", mbps))")
                    cont.resume(returning: size)
                })
            if task == nil {
                cont.resume(throwing: Insta360Error.downloadFailed("INSCameraHTTPManager returned nil task"))
            }
        }
    }

    #endif // canImport(INSCameraServiceSDK) && canImport(NetworkExtension)
}
