import Foundation
import SyncField

/// BLE-triggered Insta360 Go 3S camera stream.
///
/// Lifecycle:
/// 1. `prepare()` — no-op (framework guard only)
/// 2. `connect(context:)` — BLE pair with the camera
/// 3. `startRecording(clock:writerFactory:)` — BLE start-capture command; records ACK host-time
/// 4. `stopRecording()` — BLE stop-capture command; camera SDK returns the clip file URI
/// 5. `ingest(into:progress:)` — fetch WiFi creds over BLE, auto-switch iPhone to camera AP,
///    download mp4, restore previous WiFi, persist BLE-ACK anchor sidecar
/// 6. `disconnect()` — BLE unpair
///
/// When `INSCameraServiceSDK.xcframework` is not linked, every method throws
/// `Insta360Error.frameworkNotLinked` — the rest of SyncField is unaffected.
public final class Insta360CameraStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: true, producesFile: true,
        supportsPreciseTimestamps: true, providesAudioTrack: true)

    private var healthBus: HealthBus?
    /// Host-monotonic nanoseconds at the moment the BLE start-capture ACK was received.
    private var bleAckMonotonicNs: UInt64 = 0
    /// Camera-side file URI returned by the BLE stop-capture command.
    private var cameraFileURI: String?

    #if canImport(INSCameraServiceSDK)
    private let ble  = Insta360BLEController()
    private let wifi = Insta360WiFiDownloader()
    #endif

    public init(streamId: String) {
        self.streamId = streamId
    }

    public func prepare() async throws {
        #if !canImport(INSCameraServiceSDK)
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if canImport(INSCameraServiceSDK)
        try await ble.pair()
        await healthBus?.publish(.streamConnected(streamId: streamId))
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    /// Sends BLE start-capture command. Stores host-monotonic ACK timestamp.
    /// The camera file URI is NOT available at start-time; it arrives on stop
    /// (from the SDK's stopCapture completion with `videoInfo.uri`).
    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        #if canImport(INSCameraServiceSDK)
        self.bleAckMonotonicNs = try await ble.startRemoteRecording(clock: clock)
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    /// Sends BLE stop-capture command. The SDK returns the camera-side file URI
    /// in the completion callback — this is where cameraFileURI is populated.
    public func stopRecording() async throws -> StreamStopReport {
        #if canImport(INSCameraServiceSDK)
        self.cameraFileURI = try await ble.stopRemoteRecording()
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    public func ingest(into episodeDirectory: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        #if canImport(INSCameraServiceSDK)
        guard let uri = cameraFileURI else {
            throw Insta360Error.downloadFailed("no camera file uri recorded from stopRecording")
        }

        // 1. Fetch WiFi credentials over the existing BLE channel (already paired).
        let creds = try await ble.wifiCredentials()

        // 2. Switch iPhone onto the camera's AP, download the clip, restore previous WiFi.
        //    `wifi.download`'s `progress` is `@escaping` (it gets stored by
        //    the Insta360 SDK's HTTP socket and called asynchronously).
        //    Our `progress` parameter is non-escaping per the SyncFieldStream
        //    protocol, so wrap with `withoutActuallyEscaping` — safe because
        //    `wifi.download` only invokes the callback during its own await.
        let destination = episodeDirectory.appendingPathComponent("\(streamId).mp4")
        try await withoutActuallyEscaping(progress) { escaping in
            _ = try await wifi.download(
                remoteFileURI: uri,
                to: destination,
                ssid: creds.ssid,
                passphrase: creds.passphrase,
                progress: escaping)
        }

        // 3. Persist BLE-ACK anchor so the server can align camera-internal PTS
        //    against host monotonic ns.
        try writeInsta360SidecarAnchor(
            episodeDirectory: episodeDirectory,
            streamId: streamId,
            bleAckMonotonicNs: bleAckMonotonicNs)

        return StreamIngestReport(streamId: streamId,
                                  filePath: "\(streamId).mp4",
                                  frameCount: nil /* frame count unknown; server can probe from mp4 */)
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    public func disconnect() async throws {
        #if canImport(INSCameraServiceSDK)
        try? await ble.unpair()
        #endif
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }
}

private func writeInsta360SidecarAnchor(episodeDirectory: URL,
                                        streamId: String,
                                        bleAckMonotonicNs: UInt64) throws {
    let obj: [String: Any] = [
        "stream_id": streamId,
        "ble_ack_monotonic_ns": bleAckMonotonicNs,
        "anchor_source": "ble_ack",
    ]
    let data = try JSONSerialization.data(withJSONObject: obj,
                                          options: [.prettyPrinted, .sortedKeys])
    try data.write(to: episodeDirectory
        .appendingPathComponent("\(streamId).anchor.json"), options: [.atomic])
}
