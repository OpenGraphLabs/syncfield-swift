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
                         progress: @Sendable (Double) -> Void) async throws -> Int64 {
        try await applyHotspot(ssid: ssid, passphrase: passphrase)
        defer {
            // Belt-and-suspenders: explicit removal in addition to joinOnce=true.
            // Runs on both success and failure / cancellation paths.
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            INSCameraManager.socket().shutdown()
            NSLog("[WiFiDownloader] Hotspot config removed + SDK socket shut down (ssid=\(ssid))")
        }

        try await waitForReachability(attempts: 3)

        NSLog("[WiFiDownloader] Camera reachable — connecting SDK socket")
        INSCameraManager.socket().setup()
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 s for socket init
        INSCameraManager.socket().commandsImpl.sendHeartbeats(with: nil)

        return try await fetchResource(remoteFileURI: remoteFileURI,
                                       destination: destination,
                                       progress: progress)
    }

    // MARK: - Hotspot

    private func applyHotspot(ssid: String, passphrase: String) async throws {
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        config.joinOnce = true

        NSLog("[WiFiDownloader] Applying NEHotspotConfiguration for SSID=\(ssid)")
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
                               progress: @Sendable (Double) -> Void) async throws -> Int64 {
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
