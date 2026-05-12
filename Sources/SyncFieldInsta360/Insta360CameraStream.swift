import Foundation
import SyncField

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK
#endif

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
public final class Insta360CameraStream: SyncFieldStream, SyncFieldRecordingPreflightStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: true, producesFile: true,
        supportsPreciseTimestamps: true, providesAudioTrack: true)

    private var healthBus: HealthBus?
    /// Host-monotonic nanoseconds at the moment the BLE start-capture ACK was received.
    private var bleAckMonotonicNs: UInt64 = 0
    /// Camera-side file URI returned by the BLE stop-capture command.
    private var cameraFileURI: String?

    /// Episode directory captured at `startRecording` time so `stopRecording`
    /// can write the pending sidecar even though it isn't passed in.
    private var currentEpisodeDirectory: URL?

    /// WiFi credentials captured at `pairStandalone` time. Used by `ingest`
    /// to skip a live BLE round-trip during the WiFi AP switch.
    private var cachedCreds: (ssid: String, passphrase: String)?

    /// Callback invoked with stream lifecycle events. Set by `pairStandalone`
    /// when the bridge creates this stream outside the orchestrator's connect
    /// path; nil if the orchestrator owns the stream (uses `healthBus` instead).
    private var onHealthEvent: (@Sendable (HealthEvent) -> Void)?

    /// Callback invoked for SDK-level camera warnings (battery, storage,
    /// thermal, unexpected capture-stop). Wired by the bridge to
    /// `syncfield:cameraWarning` so a HUD banner can surface before the
    /// camera self-stops. Independent of `onHealthEvent` because these
    /// events are camera-specific.
    private var onCameraWarning: (@Sendable (Insta360CameraWarning) -> Void)?
    private let boundUUID: String?
    private let preferredBLEName: String?
    private let bindingKey: String?

    #if canImport(INSCameraServiceSDK)
    private var ble  = Insta360BLEController()
    private let wifi = Insta360WiFiDownloader()
    #endif

    public init(streamId: String) {
        self.streamId = streamId
        self.boundUUID = nil
        self.preferredBLEName = nil
        self.bindingKey = nil
    }

    /// Bind this stream to a specific CoreBluetooth peripheral UUID.
    ///
    /// Use this with `Insta360Scanner.scan()` + `identify(uuid:)` when a rig
    /// has multiple Go cameras and the host must decide which physical camera
    /// maps to which stream id.
    public init(streamId: String, uuid: String) {
        self.streamId = streamId
        self.boundUUID = uuid
        self.preferredBLEName = nil
        self.bindingKey = Insta360KnownCameraIdentity(uuid: uuid, bleName: nil).bindingKey
    }

    /// Bind this stream to a previously saved camera identity.
    ///
    /// The BLE name is important for official-app-style reconnect: it gives us
    /// the stable serial suffix used by wake-by-camera before the camera emits
    /// a fresh scan advertisement.
    public init(streamId: String, uuid: String?, preferredName: String?) {
        self.streamId = streamId
        self.boundUUID = uuid
        self.preferredBLEName = preferredName
        self.bindingKey = Insta360KnownCameraIdentity(
            uuid: uuid,
            bleName: preferredName).bindingKey
    }

    public func setCameraWarningHandler(
        _ handler: (@Sendable (Insta360CameraWarning) -> Void)?
    ) {
        self.onCameraWarning = handler
        #if canImport(INSCameraServiceSDK)
        wireWarningChannel()
        #endif
    }

    public func prepare() async throws {
        #if !canImport(INSCameraServiceSDK)
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    public func preflightRecording() async throws {
        #if canImport(INSCameraServiceSDK)
        try await ble.refreshConnection()
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if canImport(INSCameraServiceSDK)
        // If the bridge already paired this stream via `pairStandalone`,
        // `connect` is a no-op — we just store the bus reference so future
        // lifecycle events (e.g. `.streamDisconnected` on disconnect) are
        // published there too.
        if ble.connectedDeviceUUID != nil {
            return
        }
        if bindingKey != nil {
            ble = try await Insta360Scanner.shared.bindController(
                identity: Insta360KnownCameraIdentity(
                    uuid: boundUUID,
                    bleName: preferredBLEName))
            wireWarningChannel()
            do {
                self.cachedCreds = try await ble.wifiCredentials()
                await healthBus?.publish(.streamConnected(streamId: streamId))
            } catch {
                if let bindingKey {
                    await Insta360Scanner.shared.releaseBinding(uuid: bindingKey)
                    try? await Insta360Scanner.shared.unpair(uuid: bindingKey)
                }
                throw error
            }
            return
        }
        wireWarningChannel()
        try await ble.pair(excludingUUIDs: [])
        self.cachedCreds = try await ble.wifiCredentials()
        await healthBus?.publish(.streamConnected(streamId: streamId))
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    /// Pair this stream's BLE camera outside of the orchestrator's `connect()`
    /// path. The bridge uses this when the user drives pairing manually from
    /// the discovery screen (e.g. per-role wrist pairing), so each pair is a
    /// distinct awaitable that can fail, retry, and surface progress to JS.
    ///
    /// # Lifecycle-channel contract
    /// Once a stream has been paired via `pairStandalone`, its **entire**
    /// lifecycle (`.streamConnected` here, `.streamDisconnected` in
    /// `disconnect()`) is delivered via `onHealthEvent`. The orchestrator's
    /// `healthBus` is never published to for this stream, because the bus
    /// is private to the SDK. If the orchestrator then calls
    /// `connect(context:)` on this stream, it's a no-op (see that method).
    /// The bridge is responsible for forwarding `onHealthEvent` callbacks
    /// to any RN event channel so JS consumers see a consistent signal.
    public func pairStandalone(
        onHealthEvent: @escaping @Sendable (HealthEvent) -> Void,
        onCameraWarning: (@Sendable (Insta360CameraWarning) -> Void)? = nil,
        excludingUUIDs: Set<String>
    ) async throws {
        #if canImport(INSCameraServiceSDK)
        guard ble.connectedDeviceUUID == nil else {
            throw Insta360Error.commandFailed(
                "pairStandalone called on already-paired stream \(streamId)")
        }
        self.onHealthEvent = onHealthEvent
        self.onCameraWarning = onCameraWarning
        wireWarningChannel()
        if bindingKey != nil {
            ble = try await Insta360Scanner.shared.bindController(
                identity: Insta360KnownCameraIdentity(
                    uuid: boundUUID,
                    bleName: preferredBLEName))
            do {
                self.cachedCreds = try await ble.wifiCredentials()
            } catch {
                if let bindingKey {
                    await Insta360Scanner.shared.releaseBinding(uuid: bindingKey)
                    try? await Insta360Scanner.shared.unpair(uuid: bindingKey)
                }
                throw error
            }
        } else {
            try await ble.pair(excludingUUIDs: excludingUUIDs)
            self.cachedCreds = try await ble.wifiCredentials()
        }
        // Snapshot WiFi creds while BLE is freshly connected so `ingest` can
        // skip the BLE round-trip during the radio-contested hotspot switch.
        onHealthEvent(.streamConnected(streamId: streamId))
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    /// Bridge-side hub (`Insta360BluetoothHub`) owns the BLE manager and
    /// pre-pairs devices via its multi-camera scan. When the user selects
    /// a role for an already-identified camera, the hub hands the paired
    /// `INSBluetoothDevice` off to a fresh `Insta360CameraStream` through
    /// this method. The stream skips its own scan and goes straight to
    /// caching WiFi creds + publishing `.streamConnected`.
    ///
    /// # Lifecycle-channel contract
    /// Same as `pairStandalone` — the stream publishes to `onHealthEvent`
    /// for its entire lifecycle, bypassing `healthBus`.
    public func adoptPairedDevice(
        _ device: Any,
        onHealthEvent: @escaping @Sendable (HealthEvent) -> Void,
        onCameraWarning: (@Sendable (Insta360CameraWarning) -> Void)? = nil
    ) async throws {
        #if canImport(INSCameraServiceSDK)
        guard let bt = device as? INSBluetoothDevice else {
            throw Insta360Error.commandFailed(
                "adoptPairedDevice given non-INSBluetoothDevice")
        }
        guard ble.connectedDeviceUUID == nil else {
            throw Insta360Error.commandFailed(
                "adoptPairedDevice called on already-paired stream \(streamId)")
        }
        self.onHealthEvent = onHealthEvent
        self.onCameraWarning = onCameraWarning
        wireWarningChannel()
        ble.adoptConnectedDevice(bt)
        self.cachedCreds = try await ble.wifiCredentials()
        onHealthEvent(.streamConnected(streamId: streamId))
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    /// Connect the BLE controller's SDK-level warning channel through to
    /// the bridge-supplied `onCameraWarning` callback. Captures `streamId`
    /// and the callback as locals so the closure does not retain `self`.
    /// `captureStoppedUnexpectedly` is *also* mirrored as a
    /// `.streamDisconnected` health event so consumers that subscribe to
    /// the orchestrator's lifecycle channel see the interruption too.
    #if canImport(INSCameraServiceSDK)
    private func wireWarningChannel() {
        let warn = onCameraWarning
        let health = onHealthEvent
        let id = streamId
        ble.onWarning = { event in
            warn?(event)
            if case .captureStoppedUnexpectedly = event {
                health?(.streamDisconnected(streamId: id, reason: "camera_self_stopped"))
            }
        }
    }
    #endif

    /// UUID of the currently-paired camera. `nil` before pairing or after
    /// disconnect. Bridge reads this to append to its claimed-UUID set.
    public var connectedDeviceUUID: String? {
        #if canImport(INSCameraServiceSDK)
        return ble.connectedDeviceUUID
        #else
        return nil
        #endif
    }

    /// Sends BLE start-capture command. Stores host-monotonic ACK timestamp.
    /// The camera file URI is NOT available at start-time; it arrives on stop
    /// (from the SDK's stopCapture completion with `videoInfo.uri`).
    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        #if canImport(INSCameraServiceSDK)
        self.currentEpisodeDirectory = writerFactory.videoURL(streamId: streamId).deletingLastPathComponent()
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
        if let epDir = currentEpisodeDirectory,
           let uri = cameraFileURI {
            let role = streamId.hasSuffix("_ego")   ? "ego"
                       : streamId.hasSuffix("_left")  ? "left"
                       : streamId.hasSuffix("_right") ? "right"
                       : ""
            // BLE can drop between recording start and stop (Go-family
            // radios go quiet on RSSI dip / camera-side sleep), which
            // leaves `connectedDeviceUUID` / `connectedDeviceName` nil at
            // write time. Without a fallback the sidecar gets empty
            // strings — the collect path then groups multiple wrist
            // streams under the same "" key and can no longer route each
            // pending file back to its camera over WiFi. We fall through
            // to identity captured at pair time (`lastKnownDevice*`,
            // survives disconnect) and finally to `boundUUID` (passed at
            // construction for UUID-bound streams). `device.name` is
            // non-optional but may be empty before GAP name resolves —
            // treat empty as missing.
            let liveUUID = ble.connectedDeviceUUID
            let liveName: String? = {
                guard let n = ble.connectedDeviceName, !n.isEmpty else { return nil }
                return n
            }()
            let resolvedUUID = liveUUID ?? ble.lastKnownDeviceUUID ?? boundUUID ?? ""
            let resolvedName = liveName ?? ble.lastKnownDeviceName ?? ""
            if resolvedUUID.isEmpty || resolvedName.isEmpty {
                NSLog("[Insta360CameraStream] WARNING pending sidecar for \(streamId) has weak identity: uuid='\(resolvedUUID)' name='\(resolvedName)' (live uuid=\(liveUUID ?? "nil") lastKnown uuid=\(ble.lastKnownDeviceUUID ?? "nil") boundUUID=\(boundUUID ?? "nil"))")
            }
            try? Insta360PendingSidecar.write(
                to: epDir,
                streamId: streamId,
                cameraFileURI: uri,
                bleUuid: resolvedUUID,
                bleName: resolvedName,
                role: role,
                bleAckNs: bleAckMonotonicNs)
        }
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

        // 1. Use credentials captured at pair time. Fallback to live BLE fetch
        //    only if the stream was connected via the orchestrator path
        //    (older code path) — which also sets `cachedCreds` now, but we
        //    keep the fallback to avoid a hard crash on unexpected state.
        try? await ble.enableWiFiForDownload()
        let creds: (ssid: String, passphrase: String)
        if let cached = cachedCreds {
            creds = cached
        } else {
            creds = try await ble.wifiCredentials()
        }

        // 2. Switch iPhone onto the camera's AP, download the clip, restore previous WiFi.
        let destination = episodeDirectory.appendingPathComponent("\(streamId).mp4")
        try await withoutActuallyEscaping(progress) { escaping in
            _ = try await wifi.download(
                remoteFileURI: uri,
                to: destination,
                ssid: creds.ssid,
                passphrase: creds.passphrase,
                progress: escaping)
        }

        try? Insta360PendingSidecar.delete(at: episodeDirectory, streamId: streamId)

        return StreamIngestReport(streamId: streamId,
                                  filePath: "\(streamId).mp4",
                                  frameCount: nil)
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    /// Best-effort foreground recovery hook for host apps.
    ///
    /// If BLE is still connected this sends a lightweight heartbeat; if the
    /// radio silently dropped while the app was backgrounded, the controller
    /// runs the same wake + reconnect path used before start/stop commands.
    public func refreshConnection() async throws {
        #if canImport(INSCameraServiceSDK)
        try await ble.refreshConnection()
        #else
        throw Insta360Error.frameworkNotLinked
        #endif
    }

    public func disconnect() async throws {
        #if canImport(INSCameraServiceSDK)
        if let bindingKey {
            try? await Insta360Scanner.shared.unpair(uuid: bindingKey)
        } else {
            try? await ble.unpair()
        }
        cachedCreds = nil
        #endif
        let event = HealthEvent.streamDisconnected(streamId: streamId, reason: "normal")
        if let cb = onHealthEvent {
            cb(event)
        } else {
            await healthBus?.publish(event)
        }
    }

    public var pairedDeviceUUID: String? {
        #if canImport(INSCameraServiceSDK)
        return ble.lastKnownDeviceUUID
        #else
        return nil
        #endif
    }

    public var pairedDeviceName: String? {
        #if canImport(INSCameraServiceSDK)
        return ble.lastKnownDeviceName
        #else
        return nil
        #endif
    }
}
