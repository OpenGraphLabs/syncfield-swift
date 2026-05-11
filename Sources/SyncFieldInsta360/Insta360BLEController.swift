import Foundation
import SyncField

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK
#endif

/// Soft camera-health warnings surfaced by the Insta360 SDK during a
/// recording session. Distinct from `SyncField.HealthEvent` because these
/// are camera-specific and pre-empt a self-stop the user can't otherwise
/// see coming. Emitted by `Insta360BLEController.onWarning` and routed
/// through `Insta360CameraStream.onCameraWarning` to the RN bridge.
public enum Insta360CameraWarning: Sendable {
    /// SDK reports battery below the camera's internal cutoff threshold.
    /// `level` is 0–100 if the SDK's userInfo carries it, nil otherwise.
    case batteryLow(deviceName: String, level: Int?)

    /// SDK reports storage almost full. `availableMB` is best-effort from
    /// the notification's userInfo.
    case storageLow(deviceName: String, availableMB: Int?)

    /// SDK reports thermal status elevated. `level` is "warning" or
    /// "critical" (camera will self-stop imminently).
    case thermalElevated(deviceName: String, level: String)

    /// `INSCameraCaptureStopped` fired without us issuing a stop command.
    /// The clip on the SD is preserved; the next `stopRemoteRecording()`
    /// call will fail. Surface this so the user knows.
    case captureStoppedUnexpectedly(deviceName: String)

    /// Stable string for the kind, used as the JS-side discriminator.
    public var kind: String {
        switch self {
        case .batteryLow:                 return "batteryLow"
        case .storageLow:                 return "storageLow"
        case .thermalElevated:            return "thermalElevated"
        case .captureStoppedUnexpectedly: return "captureStopped"
        }
    }

    public var deviceName: String {
        switch self {
        case .batteryLow(let n, _),
             .storageLow(let n, _),
             .thermalElevated(let n, _),
             .captureStoppedUnexpectedly(let n):
            return n
        }
    }
}

#if canImport(INSCameraServiceSDK)
/// BLE controller for a single Insta360 Go 3S camera.
///
/// Ported from egonaut's `Insta360CameraManager.swift` with these changes:
/// - Single-device model (no multi-camera routing keyed by UUID)
/// - `RCTEventEmitter` ancestry removed; health events flow via `Insta360CameraStream`
/// - `startRemoteRecording` returns host-monotonic ACK nanoseconds (not a `CaptureTimestamp`)
/// - `stopRemoteRecording` returns the camera-side file URI from the SDK's `stopCapture`
///   completion block (`videoInfo?.uri`) — the URI is NOT available at start-time
/// - `wifiCredentials()` consolidates egonaut's `getWifiInfo(deviceId:)` into a
///   parameterless call (the controller owns the single connected device reference)
public final class Insta360BLEController: NSObject, @unchecked Sendable {

    // MARK: - Properties

    /// Process-wide shared `INSBluetoothManager`.
    ///
    /// `INSBluetoothManager` wraps `CBCentralManager`. CoreBluetooth peripherals
    /// are rooted in the specific central that discovered/connected them — a
    /// peripheral opened by manager A cannot have commands issued through
    /// manager B (`getCommandBy(device)` returns nil). Before the dual-camera
    /// refactor there was only one controller so one manager was fine. Now
    /// `Insta360BluetoothHub` pairs cameras and hands the `INSBluetoothDevice`
    /// off to per-stream controllers via `adoptConnectedDevice` — if the
    /// stream's controller owned its own manager, command issuance from the
    /// stream (startRemoteRecording etc) would fail because that manager
    /// never connected the peripheral.
    ///
    /// Solution: one shared manager for the whole app. Every controller and
    /// the hub reference it.
    public static let sharedManager: INSBluetoothManager = INSBluetoothManager()

    private let bluetoothManager: INSBluetoothManager

    /// Devices discovered during the most recent scan, keyed by UUID string.
    private var scannedDevices: [String: INSBluetoothDevice] = [:]

    /// The single camera device that is currently BLE-connected.
    private var connectedDevice: INSBluetoothDevice?
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatIntervalNs: UInt64 = 2_000_000_000

    private static let pairRegistryLock = NSLock()
    private static var pairedUUIDs = Set<String>()

    private static func currentlyPairedUUIDs() -> Set<String> {
        pairRegistryLock.lock(); defer { pairRegistryLock.unlock() }
        return pairedUUIDs
    }

    private static func registerPaired(_ uuid: String) {
        pairRegistryLock.lock(); defer { pairRegistryLock.unlock() }
        pairedUUIDs.insert(uuid)
    }

    private static func unregisterPaired(_ uuid: String) {
        pairRegistryLock.lock(); defer { pairRegistryLock.unlock() }
        pairedUUIDs.remove(uuid)
    }

    /// UUID of the currently-paired device, or nil if no device is paired.
    /// Bridge uses this to feed subsequent `pair(excludingUUIDs:)` calls so
    /// the second wrist pair cannot re-claim the first wrist's camera.
    public var connectedDeviceUUID: String? {
        connectedDevice?.identifierUUIDStringSafe
    }

    /// Soft-warning channel for SDK-level camera health events (battery,
    /// storage, thermal, unexpected capture-stop). Set by the owning
    /// `Insta360CameraStream` so the host app can surface a HUD banner
    /// before the camera self-stops. Kept separate from the orchestrator's
    /// `HealthEvent` because these are camera-specific (not generic stream
    /// lifecycle) and the SDK enum lives in syncfield-swift.
    public var onWarning: (@Sendable (Insta360CameraWarning) -> Void)?

    // MARK: - Pure helpers (unit-tested)

    /// Returns true iff a scanned device should be paired with.
    ///
    /// - Accepts if the advertised `name` contains "go" (case-insensitive) AND
    ///   `uuid` is not in the caller's `excluding` set.
    /// - Pure function, no Core Bluetooth dependencies — exposed `internal` so
    ///   `OGSkillTests` can cover every branch.
    public static func shouldAcceptDevice(name: String?,
                                          uuid: String,
                                          excluding: Set<String>) -> Bool {
        guard let name = name, name.lowercased().contains("go") else { return false }
        return !excluding.contains(uuid)
    }

    // MARK: - Lifecycle

    override public convenience init() {
        self.init(bluetoothManager: Insta360BLEController.sharedManager)
    }

    /// Designated initialiser. Defaults to the process-wide shared manager —
    /// pass a different manager only in tests.
    public init(bluetoothManager: INSBluetoothManager) {
        self.bluetoothManager = bluetoothManager
        super.init()
        INSCameraManager.shared().setup()
        // Delegate is set on every init — last controller wins the slot.
        // The delegate methods gate on UUID match, so stale controllers
        // correctly no-op on events not belonging to their device.
        bluetoothManager.delegate = self

        // Capture stop arrives as `NSNotification.Name.INSCameraCaptureStopped`
        // because the SDK exposes that name as a Swift extension. The other
        // three are not bridged the same way, so we attach by raw string.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCaptureStopped(_:)),
            name: NSNotification.Name.INSCameraCaptureStopped,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onBatteryLow(_:)),
            name: Notification.Name("INSCameraBatteryLowNotification"),
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onStorageStatus(_:)),
            name: Notification.Name("INSCameraStorageStatusNotification"),
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTemperatureStatus(_:)),
            name: Notification.Name("INSCameraTemperatureStatusNotification"),
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onCaptureStopped(_ notification: Notification) {
        // Camera halted recording unexpectedly (overheating, full storage,
        // battery cutoff). Normal stop goes through `stopRemoteRecording()`;
        // this observer is the only path for the unexpected case.
        let device = connectedDevice?.name ?? "(unknown)"
        NSLog("[Insta360BLE] CaptureStopped device=\(device): \(notification.userInfo ?? [:])")
        onWarning?(.captureStoppedUnexpectedly(deviceName: device))
    }

    @objc private func onBatteryLow(_ notification: Notification) {
        let device = connectedDevice?.name ?? "(unknown)"
        let level = (notification.userInfo?["batteryLevel"] as? NSNumber)?.intValue
        NSLog("[Insta360BLE] BatteryLow device=\(device) level=\(level.map(String.init) ?? "?")")
        onWarning?(.batteryLow(deviceName: device, level: level))
    }

    @objc private func onStorageStatus(_ notification: Notification) {
        let device = connectedDevice?.name ?? "(unknown)"
        // SDK sends a status enum/code; we only care that storage is constrained.
        let availableMB = (notification.userInfo?["freeSpaceMB"] as? NSNumber)?.intValue
        NSLog("[Insta360BLE] StorageStatus device=\(device) availableMB=\(availableMB.map(String.init) ?? "?")")
        onWarning?(.storageLow(deviceName: device, availableMB: availableMB))
    }

    @objc private func onTemperatureStatus(_ notification: Notification) {
        let device = connectedDevice?.name ?? "(unknown)"
        // Critical = camera will self-stop imminently; warning = elevated.
        let levelRaw = (notification.userInfo?["level"] as? NSNumber)?.intValue ?? 1
        let level = levelRaw >= 2 ? "critical" : "warning"
        NSLog("[Insta360BLE] TemperatureStatus device=\(device) level=\(level)")
        onWarning?(.thermalElevated(deviceName: device, level: level))
    }

    // MARK: - Public API

    /// BLE-pair with the first Go camera discovered during a short scan
    /// whose UUID is NOT in `excludingUUIDs`. Default behavior (empty set)
    /// matches the original single-camera semantics.
    public func pair(excludingUUIDs: Set<String> = []) async throws {
        // Wait for CoreBluetooth to become ready (up to 5 s).
        for _ in 0..<50 {
            if bluetoothManager.state == .ready { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        guard bluetoothManager.state == .ready else {
            throw Insta360Error.commandFailed("Bluetooth not ready")
        }

        let excluding = excludingUUIDs.union(Self.currentlyPairedUUIDs())

        // Scan briefly for the first Go camera.
        let device = try await withTimeout(seconds: 15) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<INSBluetoothDevice, Error>) in
                var found = false
                self.bluetoothManager.scanCameras { [weak self] device, _, _ in
                    guard let self = self, !found else { return }
                    let uuid = device.identifierUUIDStringSafe
                    guard Insta360BLEController.shouldAcceptDevice(
                        name: device.name, uuid: uuid, excluding: excluding
                    ) else { return }
                    found = true
                    self.bluetoothManager.stopScan()
                    self.scannedDevices[uuid] = device
                    cont.resume(returning: device)
                }
            }
        }

        // BLE connect.
        try await withTimeout(seconds: 15) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.bluetoothManager.connect(device) { error in
                    if let error = error {
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    cont.resume()
                }
            }
        }

        connectedDevice = device
        Self.registerPaired(device.identifierUUIDStringSafe)
        startHeartbeat()

        // Let the connection stabilise.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        NSLog("[Insta360BLE] Paired with \(Self.displayName(for: device))")
    }

    /// Disconnect the active BLE session.
    public func unpair() async throws {
        guard let device = connectedDevice else { return }
        let uuid = device.identifierUUIDStringSafe
        stopHeartbeat()
        bluetoothManager.disconnectDevice(device)
        connectedDevice = nil
        Self.unregisterPaired(uuid)
        NSLog("[Insta360BLE] Unpaired")
    }

    /// Inject a pre-paired `INSBluetoothDevice` owned by
    /// `Insta360BluetoothHub`. The stream-level controller skips its own
    /// scan and goes straight to command issuance on subsequent calls.
    public func adoptConnectedDevice(_ device: INSBluetoothDevice) {
        self.connectedDevice = device
        Self.registerPaired(device.identifierUUIDStringSafe)
        startHeartbeat()
    }

    /// BLE-advertised name of the currently-paired camera, or nil.
    public var connectedDeviceName: String? {
        connectedDevice?.name
    }

    /// Send a BLE start-capture command and return the host-monotonic nanosecond
    /// timestamp at the moment the ACK was received.
    ///
    /// **Deviation from plan C-2 skeleton:** this method returns only `UInt64` (ackNs).
    /// The camera-side file URI is not available until `stopRemoteRecording()` is called;
    /// the Insta360 SDK delivers it in the `stopCapture` completion block via `videoInfo.uri`.
    public func startRemoteRecording(clock: SessionClock) async throws -> UInt64 {
        let cmd = try commandManager()

        let captureOptions = INSCaptureOptions()
        let captureMode = INSCaptureMode()
        captureMode.mode = 1 // INSCaptureModeNormal
        captureOptions.mode = captureMode

        let deviceTag = connectedDevice?.name ?? "(unknown)"
        let sendUptimeNs = DispatchTime.now().uptimeNanoseconds
        NSLog("[Insta360BLE.timing] startCapture SEND device=\(deviceTag)")

        return try await withTimeout(seconds: 10) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
                cmd.startCapture(with: captureOptions) { error in
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - sendUptimeNs) / 1_000_000.0
                    if let error = error {
                        NSLog("[Insta360BLE.timing] startCapture FAILED device=\(deviceTag) elapsedMs=\(String(format: "%.0f", elapsedMs)): \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    NSLog("[Insta360BLE.timing] startCapture ACK device=\(deviceTag) elapsedMs=\(String(format: "%.0f", elapsedMs))")
                    let ackNs = clock.nowMonotonicNs()
                    cont.resume(returning: ackNs)
                }
            }
        }
    }

    /// Send a BLE stop-capture command and return the camera-side file URI
    /// assigned by the SDK in the completion callback (`videoInfo?.uri`).
    public func stopRemoteRecording() async throws -> String {
        let cmd = try commandManager()

        let deviceTag = connectedDevice?.name ?? "(unknown)"
        let sendUptimeNs = DispatchTime.now().uptimeNanoseconds
        NSLog("[Insta360BLE.timing] stopCapture SEND device=\(deviceTag)")

        return try await withTimeout(seconds: 15) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                cmd.stopCapture(with: nil) { error, videoInfo in
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - sendUptimeNs) / 1_000_000.0
                    if let error = error {
                        NSLog("[Insta360BLE.timing] stopCapture FAILED device=\(deviceTag) elapsedMs=\(String(format: "%.0f", elapsedMs)): \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    guard let uri = videoInfo?.uri, !uri.isEmpty else {
                        cont.resume(throwing: Insta360Error.commandFailed("stopCapture returned nil videoInfo.uri"))
                        return
                    }
                    NSLog("[Insta360BLE.timing] stopCapture ACK device=\(deviceTag) elapsedMs=\(String(format: "%.0f", elapsedMs)) uri=\(uri)")
                    cont.resume(returning: uri)
                }
            }
        }
    }

    /// Retrieve WiFi SSID and passphrase from the BLE-connected camera.
    ///
    /// Strategy (ported from egonaut `getWifiInfo`):
    /// 1. Check `device.wifiInfo` cached property.
    /// 2. Request via `getOptionsWithTypes:completion:` using performSelector
    ///    (protocol-existential limitation prevents a direct Swift call).
    /// 3. Fallback: derive SSID from BLE name + default passphrase `"88888888"`.
    public func wifiCredentials() async throws -> (ssid: String, passphrase: String) {
        guard let device = connectedDevice else {
            throw Insta360Error.notPaired
        }

        // 1. Cached property on the device object.
        if let wifi = device.wifiInfo, !wifi.ssid.isEmpty {
            let pass = wifi.password.isEmpty ? "88888888" : wifi.password
            NSLog("[Insta360BLE] WiFi creds from device.wifiInfo: SSID=\(wifi.ssid)")
            return (wifi.ssid, pass)
        }

        // 2. Explicit request: INSCameraOptionsTypeWifiInfo = 36.
        let cmd = try commandManager()
        let wifiInfoType = NSNumber(value: 36)

        do {
            let options: INSCameraOptions = try await withTimeout(seconds: 10) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<INSCameraOptions, Error>) in
                    let sel = NSSelectorFromString("getOptionsWithTypes:completion:")
                    guard (cmd as AnyObject).responds(to: sel) else {
                        cont.resume(throwing: Insta360Error.wifiCredentialsUnavailable)
                        return
                    }
                    let callback: @convention(block) (NSError?, INSCameraOptions?, NSArray?) -> Void = { error, options, _ in
                        if let error = error {
                            cont.resume(throwing: error)
                            return
                        }
                        if let options = options {
                            cont.resume(returning: options)
                        } else {
                            cont.resume(throwing: Insta360Error.wifiCredentialsUnavailable)
                        }
                    }
                    _ = (cmd as AnyObject).perform(sel, with: [wifiInfoType], with: callback)
                }
            }

            if let wifi = options.wifiInfo, !wifi.ssid.isEmpty {
                let pass = wifi.password.isEmpty ? "88888888" : wifi.password
                NSLog("[Insta360BLE] WiFi creds from getOptionsWithTypes: SSID=\(wifi.ssid)")
                return (wifi.ssid, pass)
            }
        } catch {
            NSLog("[Insta360BLE] getOptionsWithTypes WiFi fallback: \(error.localizedDescription)")
        }

        // 3. Derive SSID from BLE device name; use Insta360 Go 3S default passphrase.
        let name = device.name.isEmpty ? device.identifierUUIDStringSafe : device.name
        let ssid = name.hasSuffix(".OSC") ? name : "\(name).OSC"
        NSLog("[Insta360BLE] WiFi creds derived from BLE name: SSID=\(ssid), default passphrase")
        return (ssid, "88888888")
    }

    // MARK: - Private Helpers

    private func commandManager() throws -> INSCameraBasicCommands {
        guard let device = connectedDevice else {
            throw Insta360Error.notPaired
        }
        guard let cmd = bluetoothManager.getCommandBy(device) as? INSCameraBasicCommands else {
            throw Insta360Error.commandFailed("BLE command manager unavailable for \(Self.displayName(for: device))")
        }
        return cmd
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatIntervalNs
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        guard let cmd = try? commandManager() else { return }
        cmd.sendHeartbeats(with: nil)
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Runs `operation` with a deadline. If the deadline fires first, the
    /// operation is cancelled *and awaited* before this method returns, so
    /// any subsequent `cont.resume` inside the operation cannot double-fire
    /// an already-resumed `CheckedContinuation`.
    ///
    /// `internal static` (implicit) so `@testable import` unit tests can
    /// invoke it directly. Production instance code uses the instance
    /// wrapper below, which Swift resolves by call site.
    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Insta360Error.commandFailed(
                    "operation timed out after \(seconds)s")
            }
            defer { group.cancelAll() }
            // The winning task's result is returned. `defer` guarantees the
            // other task is cancelled; drain its completion so we don't leave
            // a continuation hanging — any thrown error there is discarded.
            let result = try await group.next()!
            while (try? await group.next()) != nil {}
            return result
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await Self.withTimeout(seconds: seconds, operation: operation)
    }
}

// MARK: - INSBluetoothManagerDelegate

extension Insta360BLEController: INSBluetoothManagerDelegate {
    public func deviceDidConnected(_ device: INSBluetoothDevice) {
        NSLog("[Insta360BLE] Device connected: \(Self.displayName(for: device))")
    }

    public func device(_ device: INSBluetoothDevice, didDisconnectWithError error: Error?) {
        NSLog("[Insta360BLE] Device disconnected: \(Self.displayName(for: device)), error: \(error?.localizedDescription ?? "none")")
        if connectedDevice?.identifierUUIDStringSafe == device.identifierUUIDStringSafe {
            Self.unregisterPaired(device.identifierUUIDStringSafe)
            stopHeartbeat()
            connectedDevice = nil
        }
    }

    fileprivate static func displayName(for device: INSBluetoothDevice) -> String {
        device.name.isEmpty ? "unknown" : device.name
    }
}

#else
public final class Insta360BLEController: @unchecked Sendable {
    public var onWarning: (@Sendable (Insta360CameraWarning) -> Void)?
    public var connectedDeviceUUID: String? { nil }
    public var connectedDeviceName: String? { nil }

    public init() {}

    public static func shouldAcceptDevice(name: String?,
                                          uuid: String,
                                          excluding: Set<String>) -> Bool {
        guard let name = name, name.lowercased().contains("go") else { return false }
        return !excluding.contains(uuid)
    }

    public func pair(excludingUUIDs _: Set<String> = []) async throws {
        throw Insta360Error.frameworkNotLinked
    }

    public func unpair() async throws {}

    public func startRemoteRecording(clock _: SessionClock) async throws -> UInt64 {
        throw Insta360Error.frameworkNotLinked
    }

    public func stopRemoteRecording() async throws -> String {
        throw Insta360Error.frameworkNotLinked
    }

    public func wifiCredentials() async throws -> (ssid: String, passphrase: String) {
        throw Insta360Error.frameworkNotLinked
    }

    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Insta360Error.commandFailed("operation timed out after \(seconds)s")
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            while (try? await group.next()) != nil {}
            return result
        }
    }
}
#endif // canImport(INSCameraServiceSDK)
