#if canImport(INSCameraServiceSDK)
import Foundation
import INSCameraServiceSDK
import SyncField

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

    private let bluetoothManager = INSBluetoothManager()

    /// Devices discovered during the most recent scan, keyed by UUID string.
    private var scannedDevices: [String: INSBluetoothDevice] = [:]

    /// The single camera device that is currently BLE-connected.
    private var connectedDevice: INSBluetoothDevice?

    // MARK: - Lifecycle

    override public init() {
        super.init()
        INSCameraManager.shared().setup()
        bluetoothManager.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCaptureStopped(_:)),
            name: NSNotification.Name.INSCameraCaptureStopped,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onCaptureStopped(_ notification: Notification) {
        // Camera halted recording unexpectedly (overheating, full storage, etc.).
        // `stopRemoteRecording()` catches the normal stop; this observer covers the
        // unexpected path so the app can surface a HealthBus event in a future revision.
        NSLog("[Insta360BLE] INSCameraCaptureStopped notification: \(notification)")
    }

    // MARK: - Public API

    /// BLE-pair with the first Go camera discovered during a short scan.
    public func pair() async throws {
        // Wait for CoreBluetooth to become ready (up to 5 s).
        for _ in 0..<50 {
            if bluetoothManager.state == .ready { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        guard bluetoothManager.state == .ready else {
            throw Insta360Error.commandFailed("Bluetooth not ready")
        }

        // Scan briefly for the first Go camera.
        let device = try await withTimeout(seconds: 15) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<INSBluetoothDevice, Error>) in
                var found = false
                self.bluetoothManager.scanCameras { [weak self] device, _, _ in
                    guard let self = self, !found else { return }
                    let name = device.name ?? ""
                    guard name.lowercased().contains("go") else { return }
                    found = true
                    self.bluetoothManager.stopScan()
                    let deviceId = device.identifierUUIDStringSafe
                    self.scannedDevices[deviceId] = device
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

        // Let the connection stabilise.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        NSLog("[Insta360BLE] Paired with \(device.name ?? "(unknown)")")
    }

    /// Disconnect the active BLE session.
    public func unpair() async throws {
        guard let device = connectedDevice else { return }
        bluetoothManager.disconnectDevice(device)
        connectedDevice = nil
        NSLog("[Insta360BLE] Unpaired")
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

        NSLog("[Insta360BLE] startCapture — mode=Normal")

        return try await withTimeout(seconds: 10) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
                cmd.startCapture(with: captureOptions) { error in
                    if let error = error {
                        NSLog("[Insta360BLE] startCapture failed: \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    let ackNs = clock.nowMonotonicNs()
                    NSLog("[Insta360BLE] startCapture ACK at \(ackNs) ns")
                    cont.resume(returning: ackNs)
                }
            }
        }
    }

    /// Send a BLE stop-capture command and return the camera-side file URI
    /// assigned by the SDK in the completion callback (`videoInfo?.uri`).
    public func stopRemoteRecording() async throws -> String {
        let cmd = try commandManager()

        return try await withTimeout(seconds: 15) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                cmd.stopCapture(with: nil) { error, videoInfo in
                    if let error = error {
                        NSLog("[Insta360BLE] stopCapture failed: \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    guard let uri = videoInfo?.uri, !uri.isEmpty else {
                        cont.resume(throwing: Insta360Error.commandFailed("stopCapture returned nil videoInfo.uri"))
                        return
                    }
                    NSLog("[Insta360BLE] stopCapture file URI: \(uri)")
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
                    (cmd as AnyObject).perform(sel, with: [wifiInfoType], with: callback)
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
        let name = device.name ?? device.identifierUUIDStringSafe
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
            throw Insta360Error.commandFailed("BLE command manager unavailable for \(device.name ?? "device")")
        }
        return cmd
    }

    private func withTimeout<T>(seconds: TimeInterval,
                                 operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Insta360Error.commandFailed("operation timed out after \(Int(seconds))s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - INSBluetoothManagerDelegate

extension Insta360BLEController: INSBluetoothManagerDelegate {
    public func deviceDidConnected(_ device: INSBluetoothDevice) {
        NSLog("[Insta360BLE] Device connected: \(device.name ?? "unknown")")
    }

    public func device(_ device: INSBluetoothDevice, didDisconnectWithError error: Error?) {
        NSLog("[Insta360BLE] Device disconnected: \(device.name ?? "unknown"), error: \(error?.localizedDescription ?? "none")")
        if connectedDevice?.identifierUUIDStringSafe == device.identifierUUIDStringSafe {
            connectedDevice = nil
        }
    }
}

#endif // canImport(INSCameraServiceSDK)
