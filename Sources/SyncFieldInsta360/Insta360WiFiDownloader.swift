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

        // Explicit cleanup (not `defer`): `defer` can't await, and iOS needs
        // a beat after `removeConfiguration` to actually disassociate from
        // the camera AP and rejoin a saved Wi-Fi. Without the wait the device
        // stays on `<camera>.OSC` until the user manually toggles Wi-Fi.
        // Critical for multi-camera (cam1 → cam2 switch) and for any host
        // app that needs internet immediately after `ingest()` returns.
        var downloadError: Error?
        var bytes: Int64 = 0
        do {
            // 8 attempts × 1 s. The AP's DHCP IP appears 1–5 s after
            // `apply` resolves; the previous 3-attempt budget was fragile
            // when iOS took longer to swing the default route.
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

        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        INSCameraManager.socket().shutdown()
        NSLog("[WiFiDownloader] Hotspot removed + SDK socket shut down (ssid=\(ssid))")
        try? await waitForSystemWiFiRestore(away: cameraHost)

        if let error = downloadError { throw error }
        return bytes
    }

    // MARK: - Hotspot

    /// Two-attempt wrapper: iOS occasionally rejects the first apply with an
    /// `internal` / `system` error code while it's still releasing a
    /// previous hotspot config (most often the previous camera's during a
    /// multi-camera batch). A single retry after a brief settle window
    /// almost always succeeds.
    private func applyHotspot(ssid: String, passphrase: String) async throws {
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
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        throw lastError ?? Insta360Error.hotspotApplyFailed("apply failed after 2 attempts")
    }

    /// Single apply attempt wrapped in a 30-second timeout.
    /// `NEHotspotConfigurationManager.apply` has no built-in deadline; if
    /// iOS' Wi-Fi state machine deadlocks (most commonly when we
    /// removeConfiguration for camera N and apply for camera N+1 in quick
    /// succession), the completion handler never fires and the entire
    /// `ingest()` would hang forever. 30 s is generous — typical apply is
    /// ~1–3 s; up to ~10 s when iOS is mid-roaming. Anything longer is
    /// genuinely stuck and we'd rather surface a clear error than spin.
    private func applyHotspotOnce(ssid: String, passphrase: String) async throws {
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        config.joinOnce = true

        NSLog("[WiFiDownloader] Applying NEHotspotConfiguration for SSID=\(ssid)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    NEHotspotConfigurationManager.shared.apply(config) { error in
                        if let ns = error as NSError? {
                            // alreadyAssociated means the device is already on this SSID — not an error.
                            if ns.domain == NEHotspotConfigurationErrorDomain,
                               ns.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                                NSLog("[WiFiDownloader] Already associated with \(ssid) — proceeding")
                                cont.resume()
                                return
                            }
                            NSLog("[WiFiDownloader] applyHotspot failed: \(ns.localizedDescription)")
                            cont.resume(throwing: Insta360Error.hotspotApplyFailed(ns.localizedDescription))
                            return
                        }
                        NSLog("[WiFiDownloader] Hotspot applied for \(ssid)")
                        cont.resume()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
                throw Insta360Error.hotspotApplyFailed("apply timed out after 30 s (iOS Wi-Fi state stuck)")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Poll until the camera AP is no longer reachable — a practical signal
    /// that iOS has disassociated and is free to either rejoin a saved
    /// Wi-Fi or fall back to cellular. Capped short because between cameras
    /// in a multi-camera batch we don't need full home-Wi-Fi rejoin; the
    /// next camera's `applyHotspot` overrides immediately.
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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            let task = http.fetchResource(
                withURI: remoteFileURI,
                toLocalFile: destination,
                progress: { p in
                    if let p = p { progress(p.fractionCompleted) }
                },
                completion: { error in
                    if let error = error {
                        NSLog("[WiFiDownloader] Download failed: \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.downloadFailed(error.localizedDescription))
                        return
                    }
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: destination.path)[.size]) as? Int64 ?? 0
                    NSLog("[WiFiDownloader] Download complete: \(destination.lastPathComponent) (\(size) bytes)")
                    cont.resume(returning: size)
                })
            if task == nil {
                cont.resume(throwing: Insta360Error.downloadFailed("INSCameraHTTPManager returned nil task"))
            }
        }
    }

    #endif // canImport(INSCameraServiceSDK) && canImport(NetworkExtension)
}
