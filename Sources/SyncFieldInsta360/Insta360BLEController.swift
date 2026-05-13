import Foundation
import SyncField

#if canImport(INSCameraServiceSDK)
@preconcurrency import INSCameraServiceSDK
#endif

private final class Insta360TimeoutResumeGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: UnsafeContinuation<T, Error>,
        _ result: Result<T, Error>
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private actor Insta360SDKCommandGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

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

/// Best-effort Action Pod dock state for GO-series cameras.
///
/// `unknown` intentionally remains usable: the SDK does not always publish
/// charge-box metadata immediately after BLE pairing, especially around
/// docking transitions.
public enum Insta360DockStatus: String, Codable, Sendable {
    case separated
    case docked
    case unknown
}

internal enum Insta360CommandReadinessProbe: Equatable, Sendable {
    case bleLinkOnly
    case commandChannel
}

internal enum Insta360CommandReadinessPolicy {
    static func probe(for reason: String) -> Insta360CommandReadinessProbe {
        let normalized = reason.lowercased()
        if normalized.contains("wificredentials")
            || normalized.contains("enablewififordownload")
            || normalized.contains("refreshconnection")
            || normalized.contains("startremoterecording")
            || normalized.contains("stopremoterecording") {
            return .commandChannel
        }
        return .bleLinkOnly
    }

    static func requiresCaptureControlProbe(for reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("refreshconnection")
            || normalized.contains("startremoterecording")
            || normalized.contains("stopremoterecording")
    }

    static func requiresPoweredGoCamera(for reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("refreshconnection")
            || normalized.contains("startremoterecording")
    }

    static func isGoCameraPoweredForRecording(powerOn: Bool, powerOnForQC: Bool) -> Bool {
        powerOn || powerOnForQC
    }

    static func shouldWakeConnectedGoCamera(powerOn: Bool, powerOnForQC: Bool) -> Bool {
        !isGoCameraPoweredForRecording(powerOn: powerOn, powerOnForQC: powerOnForQC)
    }
}

internal struct Insta360StopCaptureResult: Sendable {
    let cameraFileURI: String?
    let confirmedStopped: Bool
    let attempts: Int
    let diagnostic: String?
    let cameraDurationSec: UInt?
    let cameraFileSize: UInt64?
    let stopWallClockMs: UInt64?
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
    private let keepAlive = INSAppKeepAlive()

    /// Devices discovered during the most recent scan, keyed by UUID string.
    private var scannedDevices: [String: INSBluetoothDevice] = [:]

    /// The single camera device that is currently BLE-connected.
    private var connectedDevice: INSBluetoothDevice?

    /// Identity of the last device this controller was successfully bound
    /// to. Survives `disconnect` / `unpair`. Exists because BLE can drop
    /// mid-recording on Go-family hardware (low power radio, RSSI dip,
    /// camera-side sleep) and `stopRemoteRecording` may then write the
    /// pending-sidecar with no live identifier. The host needs the UUID
    /// and name later to re-pair and pull the file off WiFi, so we
    /// remember them here even after the live connection vanishes.
    /// Cleared only when the controller adopts a *different* device.
    private var lastKnownUUID: String?
    private var lastKnownName: String?

    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatIntervalNs: UInt64 = 2_000_000_000
    private var lastCommandReadyUptimeNs: UInt64 = 0
    private var lastCommandReadyProbe: Insta360CommandReadinessProbe?
    private let commandGate = Insta360SDKCommandGate()

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

    /// Last-known peripheral UUID this controller was bound to — survives a
    /// BLE drop. Prefer this over `connectedDeviceUUID` when persisting
    /// camera identity to disk (pending sidecars, anchor manifests), so a
    /// transient disconnect right before `stopRemoteRecording` doesn't
    /// strip the metadata. Nil only until the first successful pair/adopt.
    public var lastKnownDeviceUUID: String? {
        lastKnownUUID
    }

    /// Last-known BLE-advertised name (camera serial, e.g. "GO 3S 8E13B7").
    /// Same survival semantics as `lastKnownDeviceUUID` — this is the
    /// camera's stable hardware identifier and is the right key to use
    /// when CoreBluetooth peripheral UUIDs rotate across central-manager
    /// sessions (e.g. app cold start).
    public var lastKnownDeviceName: String? {
        lastKnownName
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
    /// - Accepts if the advertised `name` matches a Go-family BLE name AND
    ///   `uuid` is not in the caller's `excluding` set.
    /// - Pure function, no Core Bluetooth dependencies — exposed `internal` so
    ///   `OGSkillTests` can cover every branch.
    public static func shouldAcceptDevice(name: String?,
                                          uuid: String,
                                          excluding: Set<String>) -> Bool {
        guard isGoFamilyBLEName(name) else { return false }
        return !excluding.contains(uuid)
    }

    public static func isGoFamilyBLEName(_ name: String?) -> Bool {
        guard let normalized = normalizedMetadata(name)?.lowercased() else {
            return false
        }
        return normalized.hasPrefix("go ") || normalized.contains("insta360 go")
    }

    public static func isGo3SActionCamHost(
        cameraType: String?,
        go3Version: String?
    ) -> Bool {
        if normalizedMetadata(go3Version) != nil { return true }
        return isGo3CameraType(cameraType)
    }

    internal static func isAcceptableGo3SRecordingEndpoint(
        name: String?,
        cameraType: String?,
        go3Version: String?,
        boxVersion: String?
    ) -> Bool {
        actionCamHostDecision(
            name: name,
            cameraType: cameraType,
            go3Version: go3Version,
            boxVersion: boxVersion
        ).isAccepted
    }

    private enum ActionCamHostDecision: Equatable {
        case verified
        case provisionalMetadataUnavailable
        case rejected

        var isAccepted: Bool {
            switch self {
            case .verified, .provisionalMetadataUnavailable: return true
            case .rejected: return false
            }
        }
    }

    private static func actionCamHostDecision(
        name: String?,
        cameraType: String?,
        go3Version: String?,
        boxVersion: String?
    ) -> ActionCamHostDecision {
        if normalizedMetadata(go3Version) != nil { return .verified }
        if isGo3CameraType(cameraType) { return .verified }
        if normalizedMetadata(cameraType) != nil { return .rejected }
        if normalizedMetadata(boxVersion) != nil { return .rejected }
        if isGoFamilyBLEName(name) { return .provisionalMetadataUnavailable }
        return .rejected
    }

    private static func isGo3CameraType(_ cameraType: String?) -> Bool {
        guard let cameraType = normalizedMetadata(cameraType)?.lowercased() else {
            return false
        }
        let compact = cameraType.replacingOccurrences(of: " ", with: "")
        return compact.contains("go3")
    }

    private static func normalizedMetadata(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    internal static func encodeWakeId(serialLast6: String) -> String {
        serialLast6.unicodeScalars
            .prefix(6)
            .map { String(format: "%02X", $0.value) }
            .joined()
    }

    internal static func extractSerialLast6(fromBLEName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let token = trimmed.split(separator: " ").last.map(String.init),
              token.count == 6
        else { return nil }
        return token
    }

    internal static func broadcastWake(window: TimeInterval = 1.5) async {
        let manager = sharedManager
        guard manager.state == .ready else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        NSLog("[Insta360BLE.wake] broadcast SEND")
        manager.wakeUp { error in
            if let error {
                NSLog("[Insta360BLE.wake] broadcast completion error: \(error.localizedDescription)")
            }
        }
        defer {
            manager.stopWakeUpAdvertising()
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            NSLog("[Insta360BLE.wake] broadcast STOP elapsedMs=\(String(format: "%.0f", elapsedMs))")
        }
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
    }

    internal static func wake(serialLast6 serial: String, window: TimeInterval = 1.5) async {
        let manager = sharedManager
        guard manager.state == .ready else { return }
        guard serial.count == 6 else {
            await broadcastWake(window: window)
            return
        }
        let wakeId = encodeWakeId(serialLast6: serial)
        let started = DispatchTime.now().uptimeNanoseconds
        NSLog("[Insta360BLE.wake] serial=\(serial) wakeId=\(wakeId) SEND")
        manager.wakeUpSpecificCamera(wakeId) { error in
            if let error {
                NSLog("[Insta360BLE.wake] serial=\(serial) completion error: \(error.localizedDescription)")
            }
        }
        defer {
            manager.stopWakeUpAdvertising()
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            NSLog("[Insta360BLE.wake] serial=\(serial) STOP elapsedMs=\(String(format: "%.0f", elapsedMs))")
        }
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
    }

    internal func wakeAll(window: TimeInterval = 1.5) async {
        await Self.broadcastWake(window: window)
    }

    internal func wake(serialLast6 serial: String, window: TimeInterval = 1.5) async {
        await Self.wake(serialLast6: serial, window: window)
    }

    @discardableResult
    internal static func waitForCommandManagerReady(
        manager: INSBluetoothManager,
        device: INSBluetoothDevice,
        maxNs: UInt64 = 1_500_000_000,
        pollNs: UInt64 = 50_000_000
    ) async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds &- started < maxNs {
            try Task.checkCancellation()
            if manager.getCommandBy(device) != nil {
                return DispatchTime.now().uptimeNanoseconds &- started
            }
            try await Task.sleep(nanoseconds: pollNs)
        }
        return DispatchTime.now().uptimeNanoseconds &- started
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
        try Task.checkCancellation()
        // Wait for CoreBluetooth to become ready (up to 5 s).
        for _ in 0..<50 {
            if bluetoothManager.state == .ready { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        guard bluetoothManager.state == .ready else {
            throw Insta360Error.commandFailed("Bluetooth not ready")
        }

        let baseExcluding = excludingUUIDs.union(Self.currentlyPairedUUIDs())
        let preferredSerial = await preferredWakeSerial(excludingUUIDs: excludingUUIDs)

        // Scan while sending wake pulses. A Go 3S can advertise late when
        // only the Action Cam wakes and the Action Pod display remains off;
        // keep sending short targeted/broadcast bursts until scan resolves.
        let wakeTask = Task { [weak self, preferredSerial] in
            guard let self else { return }
            var cycle = 0
            while !Task.isCancelled {
                switch Insta360WakeRetryPolicy.signal(
                    serialLast6: preferredSerial,
                    cycle: cycle
                ) {
                case .targeted(let serial):
                    await self.wake(serialLast6: serial, window: 0.8)
                case .broadcast:
                    await self.wakeAll(window: 0.8)
                }
                cycle += 1
                if Task.isCancelled { break }
                try? await Task.sleep(
                    nanoseconds: Insta360WakeRetryPolicy.intervalNs(cycle: cycle))
            }
        }
        defer { wakeTask.cancel() }

        var rejectedUUIDs = Set<String>()
        var lastInvalidHostError: Error?
        for attempt in 1...4 {
            try Task.checkCancellation()
            let excluding = baseExcluding.union(rejectedUUIDs)
            let scanTimeout = rejectedUUIDs.isEmpty ? 15.0 : 6.0
            let device: INSBluetoothDevice
            do {
                device = try await scanForPairCandidate(
                    excluding: excluding,
                    timeout: scanTimeout)
            } catch {
                if let lastInvalidHostError {
                    throw lastInvalidHostError
                }
                throw error
            }

            // BLE connect.
            try Task.checkCancellation()
            do {
                try await connectScannedDevice(device)
            } catch {
                throw error
            }

            let readyNs = try await Self.waitForCommandManagerReady(
                manager: bluetoothManager,
                device: device)
            NSLog("[Insta360BLE.timing] commandManager ready after pair elapsedMs=\(String(format: "%.0f", Double(readyNs) / 1_000_000.0))")

            do {
                try await Self.assertActionCamHost(
                    device,
                    context: "pair attempt \(attempt)",
                    timeout: 1.0)
            } catch {
                lastInvalidHostError = error
                rejectedUUIDs.insert(device.identifierUUIDStringSafe)
                bluetoothManager.disconnectDevice(device)
                connectedDevice = nil
                NSLog("[Insta360BLE] rejected non-ActionCam candidate uuid=\(device.identifierUUIDStringSafe); retrying scan")
                continue
            }

            connectedDevice = device
            rememberIdentity(of: device)
            await persistIdentity(of: device)
            Self.registerPaired(device.identifierUUIDStringSafe)
            startHeartbeat()
            configureWakeOnBluetoothIfPossible(for: device)
            NSLog("[Insta360BLE] Paired with \(Self.displayName(for: device))")
            return
        }

        throw lastInvalidHostError ?? Insta360Error.commandFailed(
            "no recording ActionCam found after rejecting non-host BLE peripherals")
    }

    private func scanForPairCandidate(
        excluding: Set<String>,
        timeout: TimeInterval
    ) async throws -> INSBluetoothDevice {
        do {
            return try await withTimeout(seconds: timeout) {
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
        } catch {
            bluetoothManager.stopScan()
            throw error
        }
    }

    public func syncCameraClock(dTimeMaxMs: UInt = 2_000) async {
        guard let cmd = try? commandManager() else { return }
        do {
            try await withTimeout(seconds: 3) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    cmd.syncTimeMsToCamera(withTryCount: 3, dTimeMsMax: dTimeMaxMs) { drift, error in
                        if let error {
                            NSLog("[Insta360BLE] syncTimeMs failed: \(error.localizedDescription)")
                        } else {
                            NSLog("[Insta360BLE] syncTimeMs OK driftMs=\(drift)")
                        }
                        cont.resume()
                    }
                }
            }
        } catch {
            NSLog("[Insta360BLE] syncTimeMs timed out/skipped: \(error.localizedDescription)")
        }
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
        rememberIdentity(of: device)
        configureWakeOnBluetoothIfPossible(for: device)
        Task { await self.persistIdentity(of: device) }
        Self.registerPaired(device.identifierUUIDStringSafe)
        startHeartbeat()
    }

    public func adoptVerifiedActionCamDevice(_ device: INSBluetoothDevice) async throws {
        try await Self.assertActionCamHost(
            device,
            context: "adoptConnectedDevice",
            timeout: 1.0)
        adoptConnectedDevice(device)
    }

    internal static func waitForActionCamHostMetadata(
        device: INSBluetoothDevice,
        timeout: TimeInterval = 1.0,
        pollNs: UInt64 = 100_000_000
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutNs = UInt64(max(0, timeout) * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds &- started < timeoutNs {
            try Task.checkCancellation()
            if normalizedMetadata(device.go3Version) != nil
                || normalizedMetadata(device.cameraType) != nil
                || normalizedMetadata(device.boxVersion) != nil {
                return
            }
            try await Task.sleep(nanoseconds: pollNs)
        }
    }

    internal static func assertActionCamHost(
        _ device: INSBluetoothDevice,
        context: String,
        timeout: TimeInterval = 1.0
    ) async throws {
        try await waitForActionCamHostMetadata(device: device, timeout: timeout)
        switch actionCamHostDecision(
            name: device.name,
            cameraType: device.cameraType,
            go3Version: device.go3Version,
            boxVersion: device.boxVersion) {
        case .verified:
            return
        case .provisionalMetadataUnavailable:
            NSLog("[Insta360BLE] \(context): GO-family endpoint metadata unavailable; accepting provisionally (\(actionCamHostDiagnostic(for: device)))")
            return
        case .rejected:
            let detail = actionCamHostDiagnostic(for: device)
            NSLog("[Insta360BLE] \(context): paired peripheral is NOT an ActionCam host (\(detail)); rejecting")
            throw Insta360Error.notRecordingActionCam(detail)
        }
    }

    private static func actionCamHostDiagnostic(for device: INSBluetoothDevice) -> String {
        "name=\(displayName(for: device)) cameraType=\(normalizedMetadata(device.cameraType) ?? "nil") go3Version=\(normalizedMetadata(device.go3Version) ?? "nil") boxVersion=\(normalizedMetadata(device.boxVersion) ?? "nil") bluetoothType=\(device.bluetoothType.rawValue) isGo=\(device.isGOPeripheral()) powerOn=\(device.powerOn) powerOnForQC=\(device.powerOnForQC) lowBattery=\(device.powerForLowBatteryStatus)"
    }

    /// Cache the live device's identity so it survives a later disconnect.
    /// Captures both the CoreBluetooth peripheral UUID (this central
    /// manager's local handle) and the BLE-advertised name (the camera's
    /// stable hardware serial). Either is sufficient to find the same
    /// physical camera in a future scan; the name is preferred when
    /// central-manager UUIDs rotate across app sessions.
    private func rememberIdentity(of device: INSBluetoothDevice) {
        lastKnownUUID = device.identifierUUIDStringSafe
        let name = device.name
        if !name.isEmpty { lastKnownName = name }
    }

    private func persistIdentity(of device: INSBluetoothDevice) async {
        let name = device.name
        guard let serial = Self.extractSerialLast6(fromBLEName: name) else { return }
        await Insta360IdentityStore.shared.upsert(
            serialLast6: serial,
            uuid: device.identifierUUIDStringSafe,
            bleName: name)
    }

    private func configureWakeOnBluetoothIfPossible(for device: INSBluetoothDevice) {
        writeWakeupAuthDataIfPossible(for: device)

        // Do not opportunistically send command-channel provisioning here.
        // GO 3S often accepts the BLE link before its command channel is
        // ready; background `setOptions` / authorization probes then race
        // recording preflight and can poison the SDK connection with 444
        // disconnects. Wake provisioning needs an explicit foreground flow.
    }

    private func writeWakeupAuthDataIfPossible(for device: INSBluetoothDevice) {
        guard let cmd = bluetoothManager.getCommandBy(device) as? INSCameraCommandManager,
              let sessionManager = cmd.messageSender as? INSCameraSessionManager,
              let connection = sessionManager.connection as? INSBluetoothConnection
        else {
            NSLog("[Insta360BLE.wake] Wake auth connection unavailable for \(Self.displayName(for: device))")
            return
        }
        connection.writeWakeupAuthDataToCamera()
        NSLog("[Insta360BLE.wake] Wake auth data written for \(Self.displayName(for: device))")
    }

    private func preferredWakeSerial(excludingUUIDs: Set<String>) async -> String? {
        if let name = lastKnownName,
           let serial = Self.extractSerialLast6(fromBLEName: name) {
            return serial
        }

        // The no-UUID single-camera path historically paired with the first
        // visible GO camera. If the SDK knows exactly one prior camera, target
        // wake to that serial; otherwise broadcast so multi-camera discovery
        // remains unbiased.
        guard excludingUUIDs.isEmpty else { return nil }
        let records = await Insta360IdentityStore.shared.all()
        return records.count == 1 ? records[0].serialLast6 : nil
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
        try Task.checkCancellation()
        return try await withControllerCommandGate(label: "startRemoteRecording") {
            try await self.startRemoteRecordingLocked(clock: clock)
        }
    }

    private func startRemoteRecordingLocked(clock: SessionClock) async throws -> UInt64 {
        var lastError: Error?
        for attempt in 1...Insta360CaptureRetryPolicy.maxStartAttempts {
            try Task.checkCancellation()
            do {
                try await ensureCommandReady(
                    reason: "startRemoteRecording attempt \(attempt)",
                    maxCachedAgeSeconds: attempt == 1 ? 8 : 0)
                let cmd = try commandManager()
                await configureRecordingSafetyLimitIfPossible(cmd: cmd)
                return try await performStartCapture(
                    cmd: cmd,
                    clock: clock,
                    timeoutSeconds: Insta360CaptureRetryPolicy.startTimeoutSeconds(attempt: attempt))
            } catch {
                lastError = error
                guard attempt < Insta360CaptureRetryPolicy.maxStartAttempts,
                      Insta360CaptureRetryPolicy.isRecoverableCommandError(error) else {
                    throw error
                }
                NSLog("[Insta360BLE.timing] startCapture recoverable failure attempt=\(attempt): \(error.localizedDescription); forcing wake/reconnect before retry")
                await cleanupAmbiguousStartFailure(reason: "startCapture attempt \(attempt) failed")
            }
        }
        throw lastError ?? Insta360Error.commandFailed("startCapture failed")
    }

    private func performStartCapture(
        cmd: INSCameraBasicCommands,
        clock: SessionClock,
        timeoutSeconds: TimeInterval
    ) async throws -> UInt64 {
        let captureOptions = INSCaptureOptions()
        let captureMode = INSCaptureMode()
        captureMode.mode = 1 // INSCaptureModeNormal
        captureOptions.mode = captureMode

        let deviceTag = connectedDevice?.name ?? "(unknown)"
        let sendUptimeNs = DispatchTime.now().uptimeNanoseconds
        NSLog("[Insta360BLE.timing] startCapture SEND device=\(deviceTag)")

        return try await withTimeout(seconds: timeoutSeconds) {
            try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<UInt64, Error>) in
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

    private func configureRecordingSafetyLimitIfPossible(cmd: INSCameraBasicCommands) async {
        let options = INSCameraOptions()
        options.captureTimeLimit = Insta360CaptureRetryPolicy.recordingSafetyLimitSeconds
        let captureTimeLimitType = NSNumber(value: 7) // INSCameraOptionsTypeCaptureTimeLimit

        do {
            try await withTimeout(seconds: 3) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    cmd.setOptions(options, forTypes: [captureTimeLimitType]) { error, _ in
                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        cont.resume()
                    }
                }
            }
            NSLog("[Insta360BLE] recording safety limit set to \(Insta360CaptureRetryPolicy.recordingSafetyLimitSeconds)s")
        } catch {
            // Some firmware rejects this option; stop reliability must not depend on it.
            NSLog("[Insta360BLE] recording safety limit skipped: \(error.localizedDescription)")
        }
    }

    /// Send a BLE stop-capture command and return the camera-side file URI
    /// assigned by the SDK in the completion callback (`videoInfo?.uri`).
    public func stopRemoteRecording() async throws -> String {
        let result = try await stopRemoteRecordingReliably()
        guard let uri = result.cameraFileURI, !uri.isEmpty else {
            throw Insta360Error.commandFailed(
                result.diagnostic ?? "stopCapture confirmed stop but returned no video URI")
        }
        return uri
    }

    func stopRemoteRecordingReliably() async throws -> Insta360StopCaptureResult {
        try Task.checkCancellation()
        return try await withControllerCommandGate(label: "stopRemoteRecording") {
            try await self.stopRemoteRecordingLocked()
        }
    }

    private func stopRemoteRecordingLocked() async throws -> Insta360StopCaptureResult {
        var lastError: Error?

        for attempt in 1...Insta360CaptureRetryPolicy.maxStopAttempts {
            try Task.checkCancellation()

            do {
                try await ensureCommandReady(
                    reason: "stopRemoteRecording attempt \(attempt)",
                    maxCachedAgeSeconds: attempt == 1 ? 8 : 0)
            } catch {
                lastError = error
                if attempt < Insta360CaptureRetryPolicy.maxStopAttempts {
                    try? await Task.sleep(
                        nanoseconds: Insta360CaptureRetryPolicy.stopBackoffNs(afterAttempt: attempt))
                    continue
                }
                break
            }

            let stopWallClockMs = UInt64(Date().timeIntervalSince1970 * 1000)
            do {
                let cmd = try commandManager()
                let result = try await performStopCapture(
                    cmd: cmd,
                    timeoutSeconds: Insta360CaptureRetryPolicy.stopTimeoutSeconds(attempt: attempt),
                    attempt: attempt)
                let uri = result.uri.trimmingCharacters(in: .whitespacesAndNewlines)
                return Insta360StopCaptureResult(
                    cameraFileURI: uri.isEmpty ? nil : uri,
                    confirmedStopped: true,
                    attempts: attempt,
                    diagnostic: uri.isEmpty ? "stopCapture acked without uri" : nil,
                    cameraDurationSec: result.totalTime > 0 ? UInt(result.totalTime) : nil,
                    cameraFileSize: result.fileSize > 0 ? result.fileSize : nil,
                    stopWallClockMs: stopWallClockMs)
            } catch {
                lastError = error
                if Insta360CaptureRetryPolicy.indicatesAlreadyStopped(error) {
                    let status = await waitForCameraToStopRecording(maxSeconds: 3)
                    NSLog("[Insta360BLE.timing] stopCapture already stopped after attempt=\(attempt): \(error.localizedDescription)")
                    return Insta360StopCaptureResult(
                        cameraFileURI: nil,
                        confirmedStopped: true,
                        attempts: attempt,
                        diagnostic: error.localizedDescription,
                        cameraDurationSec: status.captureTime > 0 ? status.captureTime : nil,
                        cameraFileSize: nil,
                        stopWallClockMs: stopWallClockMs)
                }

                let status = await waitForCameraToStopRecording(maxSeconds: 10)
                if status.didStop {
                    return Insta360StopCaptureResult(
                        cameraFileURI: nil,
                        confirmedStopped: true,
                        attempts: attempt,
                        diagnostic: "stopCapture callback failed but captureState reports stopped (\(error.localizedDescription))",
                        cameraDurationSec: status.captureTime > 0 ? status.captureTime : nil,
                        cameraFileSize: nil,
                        stopWallClockMs: stopWallClockMs)
                }

                guard attempt < Insta360CaptureRetryPolicy.maxStopAttempts else {
                    break
                }

                NSLog("[Insta360BLE.timing] stop attempt=\(attempt) still recording per state probe; cycling BLE")
                if let device = connectedDevice {
                    markConnectedDeviceStale(
                        device,
                        reason: "stopCapture attempt \(attempt) failed AND state still recording")
                }
                await wakeKnownCamera(window: attempt == 1 ? 0.8 : 1.2)
                try? await Task.sleep(
                    nanoseconds: Insta360CaptureRetryPolicy.stopBackoffNs(afterAttempt: attempt))
            }
        }

        let diagnostic = lastError?.localizedDescription ?? "stopCapture failed without an SDK error"
        throw Insta360Error.commandFailed(
            "stopCapture could not confirm camera stop after \(Insta360CaptureRetryPolicy.maxStopAttempts) attempts; last error: \(diagnostic)")
    }

    private func performStopCapture(
        cmd: INSCameraBasicCommands,
        timeoutSeconds: TimeInterval,
        attempt: Int
    ) async throws -> (uri: String, totalTime: UInt32, fileSize: UInt64) {
        let deviceTag = connectedDevice?.name ?? "(unknown)"
        let sendUptimeNs = DispatchTime.now().uptimeNanoseconds
        NSLog("[Insta360BLE.timing] stopCapture SEND device=\(deviceTag) attempt=\(attempt)")

        return try await withTimeout(seconds: timeoutSeconds) {
            try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<(String, UInt32, UInt64), Error>) in
                cmd.stopCapture(with: nil) { error, videoInfo in
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - sendUptimeNs) / 1_000_000.0
                    if let error = error {
                        NSLog("[Insta360BLE.timing] stopCapture FAILED device=\(deviceTag) attempt=\(attempt) elapsedMs=\(String(format: "%.0f", elapsedMs)): \(error.localizedDescription)")
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    let uri = videoInfo?.uri ?? ""
                    let totalTime = videoInfo?.totalTime ?? 0
                    let fileSize = videoInfo?.fileSize ?? 0
                    NSLog("[Insta360BLE.timing] stopCapture ACK device=\(deviceTag) elapsedMs=\(String(format: "%.0f", elapsedMs)) uri=\(uri.isEmpty ? "<empty>" : uri) totalTime=\(totalTime) fileSize=\(fileSize)")
                    cont.resume(returning: (uri, totalTime, fileSize))
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
        let initialDevice = connectedDevice
        let initialName = lastKnownName ?? initialDevice?.name
        let serial = initialName.flatMap(Self.extractSerialLast6(fromBLEName:))

        if let serial,
           let cached = await Insta360IdentityStore.shared.wifiCreds(forSerial: serial) {
            NSLog("[Insta360BLE] WiFi creds from identity cache: SSID=\(cached.ssid)")
            return cached
        }

        // 1. Cached property on the device object.
        if initialDevice == nil {
            do {
                try await ensureCommandReady(
                    reason: "wifiCredentials",
                    maxCachedAgeSeconds: 5)
            } catch {
                if let name = initialName {
                    return await derivedWiFiCredentials(fromBLEName: name, serial: serial)
                }
                throw error
            }
        }

        guard let device = connectedDevice else {
            if let name = initialName {
                return await derivedWiFiCredentials(fromBLEName: name, serial: serial)
            }
            throw Insta360Error.notPaired
        }

        if let wifi = device.wifiInfo, !wifi.ssid.isEmpty {
            let pass = wifi.password.isEmpty ? "88888888" : wifi.password
            if let serial {
                await Insta360IdentityStore.shared.setWifiCreds(
                    (wifi.ssid, pass),
                    forSerial: serial)
            }
            NSLog("[Insta360BLE] WiFi creds from device.wifiInfo: SSID=\(wifi.ssid)")
            return (wifi.ssid, pass)
        }

        do {
            try await ensureCommandReady(
                reason: "wifiCredentials",
                maxCachedAgeSeconds: 5)
        } catch {
            NSLog("[Insta360BLE] WiFi command readiness skipped, deriving creds: \(error.localizedDescription)")
            return await derivedWiFiCredentials(fromBLEName: device.name, serial: serial)
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
                if let serial {
                    await Insta360IdentityStore.shared.setWifiCreds(
                        (wifi.ssid, pass),
                        forSerial: serial)
                }
                NSLog("[Insta360BLE] WiFi creds from getOptionsWithTypes: SSID=\(wifi.ssid)")
                return (wifi.ssid, pass)
            }
        } catch {
            NSLog("[Insta360BLE] getOptionsWithTypes WiFi fallback: \(error.localizedDescription)")
        }

        // 3. Derive SSID from BLE device name; use Insta360 Go 3S default passphrase.
        return await derivedWiFiCredentials(
            fromBLEName: device.name.isEmpty ? device.identifierUUIDStringSafe : device.name,
            serial: serial)
    }

    private func derivedWiFiCredentials(
        fromBLEName bleName: String,
        serial: String?
    ) async -> (ssid: String, passphrase: String) {
        let name = bleName.isEmpty ? (lastKnownName ?? "Insta360") : bleName
        let ssid = name.hasSuffix(".OSC") ? name : "\(name).OSC"
        if let serial {
            await Insta360IdentityStore.shared.setWifiCreds(
                (ssid, "88888888"),
                forSerial: serial)
        }
        NSLog("[Insta360BLE] WiFi creds derived from BLE name: SSID=\(ssid), default passphrase")
        return (ssid, "88888888")
    }

    public func enableWiFiForDownload() async throws {
        try await ensureCommandReady(
            reason: "enableWiFiForDownload",
            maxCachedAgeSeconds: 5)
        let cmd = try commandManager()
        let options = INSCameraOptions()
        options.wifiStatus = INSCameraWifiStatus(rawValue: 1)!
        let wifiStatusType = NSNumber(value: 43)

        do {
            try await withTimeout(seconds: 8) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    cmd.setOptions(options, forTypes: [wifiStatusType]) { error, _ in
                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        cont.resume()
                    }
                }
            }
            NSLog("[Insta360BLE] WiFi radio enable requested")
        } catch {
            // Some firmware keeps Wi-Fi in auto mode and rejects this option
            // while still serving the AP. Treat this as a latency hint, not as
            // a hard precondition for download.
            NSLog("[Insta360BLE] WiFi radio enable skipped: \(error.localizedDescription)")
        }
    }

    public func refreshConnection() async throws {
        try await withControllerCommandGate(label: "refreshConnection") {
            try await self.ensureCommandReady(
                reason: "refreshConnection",
                maxCachedAgeSeconds: 0)
        }
    }

    /// Best-effort stop warmup that does not acquire the command gate.
    ///
    /// The actual stop path still performs `ensureCommandReady` and confirms
    /// capture state. This method only sends a short targeted wake burst so a
    /// Go-series camera whose low-power BLE radio got quiet during a long take
    /// is more likely to be advertising by the time `stopCapture` runs.
    public func prepareForStopRecording() async {
        await wakeKnownCamera(window: 0.8)
    }

    // MARK: - Private Helpers

    private func ensureCommandReady(
        reason: String,
        maxCachedAgeSeconds: TimeInterval
    ) async throws {
        let probePolicy = Insta360CommandReadinessPolicy.probe(for: reason)
        let now = DispatchTime.now().uptimeNanoseconds
        if maxCachedAgeSeconds > 0,
           connectedDevice != nil,
           lastCommandReadyUptimeNs > 0,
           (lastCommandReadyProbe == .commandChannel || probePolicy == .bleLinkOnly),
           now &- lastCommandReadyUptimeNs < UInt64(maxCachedAgeSeconds * 1_000_000_000) {
            return
        }

        var lastError: Error?
        for attempt in 1...3 {
            if connectedDevice == nil {
                do {
                    try await reconnectIfNeeded()
                } catch {
                    lastError = error
                    NSLog("[Insta360BLE] \(reason) reconnect attempt=\(attempt) failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                    continue
                }
            }

            guard let device = connectedDevice else {
                lastError = Insta360Error.notPaired
                continue
            }

            if shouldWakeBeforeProbe(device) {
                await wakeKnownCamera(window: attempt == 1 ? 0.45 : 0.8)
            }

            guard await isBLELinkReachable(device, timeout: attempt == 1 ? 2 : 3) else {
                lastError = Insta360Error.commandFailed("BLE link probe timed out")
                markConnectedDeviceStale(device, reason: "\(reason) RSSI probe failed")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                continue
            }

            if Insta360CommandReadinessPolicy.requiresPoweredGoCamera(for: reason) {
                do {
                    try ensurePoweredGoCameraForRecording(device, reason: reason)
                } catch {
                    lastError = error
                    NSLog("[Insta360BLE] \(reason) power probe failed: \(error.localizedDescription)")
                    throw error
                }
            }

            do {
                _ = try commandManager()
            } catch {
                lastError = error
                NSLog("[Insta360BLE] \(reason) command manager unavailable attempt=\(attempt): \(error.localizedDescription)")
                markConnectedDeviceStale(device, reason: "\(reason) command manager unavailable")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                continue
            }

            guard probePolicy == .commandChannel else {
                lastCommandReadyUptimeNs = DispatchTime.now().uptimeNanoseconds
                lastCommandReadyProbe = probePolicy
                return
            }

            do {
                if Insta360CommandReadinessPolicy.requiresCaptureControlProbe(for: reason) {
                    try await probeCaptureControlChannel(timeout: attempt == 1 ? 4 : 6)
                } else {
                    try await probeCommandChannel(timeout: attempt == 1 ? 4 : 6)
                }
                lastCommandReadyUptimeNs = DispatchTime.now().uptimeNanoseconds
                lastCommandReadyProbe = probePolicy
                return
            } catch {
                lastError = error
                NSLog("[Insta360BLE] \(reason) command probe attempt=\(attempt) failed: \(error.localizedDescription)")
                markConnectedDeviceStale(device, reason: "\(reason) command probe failed")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
            }
        }

        throw lastError ?? Insta360Error.commandFailed("\(reason) failed")
    }

    private func ensurePoweredGoCameraForRecording(
        _ device: INSBluetoothDevice,
        reason: String
    ) throws {
        guard device.isGOPeripheral() else { return }
        NSLog("[Insta360BLE] power probe device=\(Self.displayName(for: device)) reason=\(reason) powerOn=\(device.powerOn) powerOnForQC=\(device.powerOnForQC) lowBattery=\(device.powerForLowBatteryStatus)")
        guard Insta360CommandReadinessPolicy.isGoCameraPoweredForRecording(
            powerOn: device.powerOn,
            powerOnForQC: device.powerOnForQC
        ) else {
            if device.powerForLowBatteryStatus {
                throw Insta360Error.commandFailed("camera is in low battery power-off state")
            }
            throw Insta360Error.commandFailed("camera is not powered on")
        }
    }

    private func shouldWakeBeforeProbe(_ device: INSBluetoothDevice) -> Bool {
        guard device.isGOPeripheral() else { return false }
        return Insta360CommandReadinessPolicy.shouldWakeConnectedGoCamera(
            powerOn: device.powerOn,
            powerOnForQC: device.powerOnForQC)
    }

    private func wakeKnownCamera(window: TimeInterval) async {
        if let name = lastKnownName,
           let serial = Self.extractSerialLast6(fromBLEName: name) {
            await Self.wake(serialLast6: serial, window: window)
        } else {
            await Self.broadcastWake(window: window)
        }
    }

    private func isBLELinkReachable(
        _ device: INSBluetoothDevice,
        timeout: TimeInterval
    ) async -> Bool {
        do {
            try await withTimeout(seconds: timeout) {
                try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<Void, Error>) in
                    self.bluetoothManager.readRSSI(device) { error, rssi in
                        if let error {
                            cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                            return
                        }
                        NSLog("[Insta360BLE] RSSI probe device=\(Self.displayName(for: device)) rssi=\(rssi?.stringValue ?? "?")")
                        cont.resume()
                    }
                }
            }
            return true
        } catch {
            NSLog("[Insta360BLE] RSSI probe failed device=\(Self.displayName(for: device)): \(error.localizedDescription)")
            return false
        }
    }

    private func probeCommandChannel(timeout: TimeInterval) async throws {
        let cmd = try commandManager()
        let optionTypes = [NSNumber(value: 11)] // INSCameraOptionsTypeBatteryStatus
        try await withTimeout(seconds: timeout) {
            try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<Void, Error>) in
                let sel = NSSelectorFromString("getOptionsWithTypes:completion:")
                guard (cmd as AnyObject).responds(to: sel) else {
                    cont.resume(throwing: Insta360Error.commandFailed("BLE getOptions unavailable"))
                    return
                }
                let callback: @convention(block) (NSError?, INSCameraOptions?, NSArray?) -> Void = { error, _, successTypes in
                    if let error {
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    NSLog("[Insta360BLE] command probe ACK successTypeCount=\(successTypes?.count ?? 0)")
                    cont.resume()
                }
                _ = (cmd as AnyObject).perform(sel, with: optionTypes, with: callback)
            }
        }
    }

    private func probeCaptureControlChannel(timeout: TimeInterval) async throws {
        let result = try await currentCaptureState(timeout: timeout)
        NSLog("[Insta360BLE] capture control probe ACK state=\(result.stateRaw) captureTime=\(result.captureTime)")
    }

    private func currentCaptureState(
        timeout: TimeInterval = 3
    ) async throws -> (stateRaw: UInt, captureTime: UInt) {
        let cmd = try commandManager()
        return try await withTimeout(seconds: timeout) {
            try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<(UInt, UInt), Error>) in
                cmd.getCurrentCaptureStatus { error, status in
                    if let error {
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    guard let status else {
                        cont.resume(throwing: Insta360Error.commandFailed(
                            "getCurrentCaptureStatus returned nil"))
                        return
                    }
                    cont.resume(returning: (
                        UInt(status.state.rawValue),
                        UInt(status.captureTime)))
                }
            }
        }
    }

    private func waitForCameraToStopRecording(
        maxSeconds: TimeInterval = 10
    ) async -> (didStop: Bool, captureTime: UInt) {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(maxSeconds * 1_000_000_000)
        var lastCaptureTime: UInt = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let result = try? await currentCaptureState(timeout: 2) {
                lastCaptureTime = result.captureTime
                if result.stateRaw == 0 {
                    NSLog("[Insta360BLE.timing] captureState confirmed stop captureTime=\(result.captureTime)")
                    return (true, result.captureTime)
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return (false, lastCaptureTime)
    }

    private func cleanupAmbiguousStartFailure(reason: String) async {
        if let device = connectedDevice {
            markConnectedDeviceStale(device, reason: reason)
        }

        do {
            try await ensureCommandReady(
                reason: "\(reason) cleanup",
                maxCachedAgeSeconds: 0)
            await bestEffortStopCaptureAfterAmbiguousStart()
        } catch {
            NSLog("[Insta360BLE.timing] ambiguous start cleanup could not reconnect: \(error.localizedDescription)")
        }
    }

    private func bestEffortStopCaptureAfterAmbiguousStart(timeoutSeconds: TimeInterval = 5) async {
        guard let cmd = try? commandManager() else { return }
        let deviceTag = connectedDevice?.name ?? "(unknown)"
        do {
            try await withTimeout(seconds: timeoutSeconds) {
                try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<Void, Error>) in
                    cmd.stopCapture(with: nil) { error, _ in
                        if let error {
                            NSLog("[Insta360BLE.timing] cleanup stopCapture skipped device=\(deviceTag): \(error.localizedDescription)")
                        } else {
                            NSLog("[Insta360BLE.timing] cleanup stopCapture ACK device=\(deviceTag)")
                        }
                        cont.resume()
                    }
                }
            }
        } catch {
            NSLog("[Insta360BLE.timing] cleanup stopCapture timeout device=\(deviceTag): \(error.localizedDescription)")
        }
    }

    private func markConnectedDeviceStale(
        _ device: INSBluetoothDevice,
        reason: String
    ) {
        NSLog("[Insta360BLE] marking connection stale device=\(Self.displayName(for: device)) reason=\(reason)")
        stopHeartbeat()
        bluetoothManager.disconnectDevice(device)
        connectedDevice = nil
        lastCommandReadyUptimeNs = 0
        lastCommandReadyProbe = nil
        Self.unregisterPaired(device.identifierUUIDStringSafe)
    }

    private func withControllerCommandGate<T: Sendable>(
        label: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        await commandGate.acquire()
        NSLog("[Insta360BLE.gate] \(label) acquired")
        do {
            try Task.checkCancellation()
            let value = try await operation()
            NSLog("[Insta360BLE.gate] \(label) release")
            await commandGate.release()
            return value
        } catch {
            NSLog("[Insta360BLE.gate] \(label) release after error: \(error.localizedDescription)")
            await commandGate.release()
            throw error
        }
    }

    private func commandManager() throws -> INSCameraBasicCommands {
        guard let device = connectedDevice else {
            throw Insta360Error.notPaired
        }
        guard let cmd = bluetoothManager.getCommandBy(device) as? INSCameraBasicCommands else {
            throw Insta360Error.commandFailed("BLE command manager unavailable for \(Self.displayName(for: device))")
        }
        return cmd
    }

    /// Best-effort BLE reconnect using the cached identity. Called as a
    /// safety net before any command that requires a live session
    /// (`startRemoteRecording`, `stopRemoteRecording`, `wifiCredentials`)
    /// so a transient mid-recording disconnect doesn't lose the camera-
    /// side file URI when the user finally taps stop.
    ///
    /// No-op when already connected. Returns silently after one
    /// successful reconnect; on failure, propagates the underlying
    /// scan/connect error so the caller's existing error path runs.
    private func reconnectIfNeeded() async throws {
        if connectedDevice != nil { return }
        let targetUUID = lastKnownUUID
        let targetSerial = lastKnownName.flatMap(Self.extractSerialLast6(fromBLEName:))
        guard targetUUID != nil || targetSerial != nil else {
            throw Insta360Error.notPaired
        }
        NSLog("[Insta360BLE] reconnectIfNeeded — re-pairing uuid=\(targetUUID ?? "nil") serial=\(targetSerial ?? "nil")")

        // CoreBluetooth needs a beat to settle after a disconnect before
        // it'll start a fresh scan reliably. Same poll pattern as `pair`.
        for _ in 0..<50 {
            try Task.checkCancellation()
            if bluetoothManager.state == .ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard bluetoothManager.state == .ready else {
            throw Insta360Error.commandFailed("Bluetooth not ready during reconnect")
        }

        let identity = Insta360KnownCameraIdentity(
            uuid: targetUUID,
            bleName: lastKnownName)
        let wakeTask = Task { [identity] in
            var cycle = 0
            while !Task.isCancelled {
                switch Insta360WakeRetryPolicy.signal(
                    serialLast6: identity.serialLast6,
                    cycle: cycle
                ) {
                case .targeted(let serial):
                    await Self.wake(serialLast6: serial, window: 0.8)
                case .broadcast:
                    await Self.broadcastWake(window: 0.8)
                }
                cycle += 1
                if Task.isCancelled { break }
                try? await Task.sleep(
                    nanoseconds: Insta360WakeRetryPolicy.intervalNs(cycle: cycle))
            }
        }
        defer {
            wakeTask.cancel()
            keepAlive.stop()
        }

        if let name = identity.preferredBLEName {
            keepAlive.setDeviceNameMappingTable([name: name])
            keepAlive.start(withCamerName: name)
            do {
                let device = try await withTimeout(seconds: 10) {
                    try await self.connectWithName(name)
                }
                try await finishReconnect(with: device)
                return
            } catch {
                NSLog("[Insta360BLE] reconnect connectWithName failed name=\(name): \(error.localizedDescription)")
            }
        }

        if let uuidString = targetUUID,
           let uuid = UUID(uuidString: uuidString) {
            do {
                let device = try await withTimeout(seconds: 6) {
                    try await self.connectWithUUID(uuid)
                }
                try await finishReconnect(with: device)
                return
            } catch {
                NSLog("[Insta360BLE] reconnect connectWithUUID failed uuid=\(uuidString): \(error.localizedDescription)")
            }
        }

        // Targeted scan: the original UUID or the stable serial counts as a
        // hit. Go 3S in deep sleep advertises at ~1 Hz, so the 10 s budget
        // covers the common case where the camera slept right after the drop.
        let device = try await withTimeout(seconds: 10) {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<INSBluetoothDevice, Error>) in
                var found = false
                self.bluetoothManager.scanCameras { [weak self] device, _, _ in
                    guard let self = self, !found else { return }
                    let scanUUID = device.identifierUUIDStringSafe
                    let scanSerial = Self.extractSerialLast6(fromBLEName: device.name)
                    let uuidMatches = targetUUID.map { scanUUID == $0 } ?? false
                    let serialMatches = targetSerial.map { scanSerial == $0 } ?? false
                    guard uuidMatches || serialMatches else { return }
                    found = true
                    self.bluetoothManager.stopScan()
                    self.scannedDevices[scanUUID] = device
                    cont.resume(returning: device)
                }
            }
        }

        try await connectScannedDevice(device)
        try await finishReconnect(with: device)
    }

    private func finishReconnect(with device: INSBluetoothDevice) async throws {
        try Task.checkCancellation()
        connectedDevice = device
        let readyNs = try await Self.waitForCommandManagerReady(
            manager: bluetoothManager,
            device: device)
        NSLog("[Insta360BLE.timing] commandManager ready after reconnect elapsedMs=\(String(format: "%.0f", Double(readyNs) / 1_000_000.0))")
        do {
            try await Self.assertActionCamHost(
                device,
                context: "reconnect",
                timeout: 1.0)
        } catch {
            bluetoothManager.disconnectDevice(device)
            connectedDevice = nil
            Self.unregisterPaired(device.identifierUUIDStringSafe)
            throw error
        }
        rememberIdentity(of: device)
        await persistIdentity(of: device)
        Self.registerPaired(device.identifierUUIDStringSafe)
        startHeartbeat()
        configureWakeOnBluetoothIfPossible(for: device)
        NSLog("[Insta360BLE] reconnectIfNeeded — re-paired \(Self.displayName(for: device))")
    }

    private func connectScannedDevice(_ device: INSBluetoothDevice) async throws {
        try await withTimeout(seconds: 10) {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, Error>) in
                self.bluetoothManager.connect(device) { error in
                    if let error = error {
                        cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    private func connectWithName(_ name: String) async throws -> INSBluetoothDevice {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<INSBluetoothDevice, Error>) in
            bluetoothManager.connect(withName: name) { error, device in
                if let error {
                    cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                    return
                }
                guard let device else {
                    cont.resume(throwing: Insta360Error.deviceNotDiscovered(name))
                    return
                }
                cont.resume(returning: device)
            }
        }
    }

    private func connectWithUUID(_ uuid: UUID) async throws -> INSBluetoothDevice {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<INSBluetoothDevice, Error>) in
            bluetoothManager.connect(with: uuid) { error, device in
                if let error {
                    cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                    return
                }
                guard let device else {
                    cont.resume(throwing: Insta360Error.deviceNotDiscovered(uuid.uuidString))
                    return
                }
                cont.resume(returning: device)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatIntervalNs
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                _ = self?.sendHeartbeat()
            }
        }
    }

    @discardableResult
    private func sendHeartbeat() -> Bool {
        guard let cmd = try? commandManager() else { return false }
        cmd.sendHeartbeats(with: nil)
        return true
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Runs `operation` with a deadline.
    ///
    /// The Insta360 SDK often reports failure by invoking an Objective-C
    /// callback later rather than by cooperating with Swift task
    /// cancellation. A structured task group would wait for that late
    /// callback before leaving scope, which defeats the purpose of a timeout
    /// and strands the UI. This wrapper races unstructured tasks instead:
    /// callers regain control at the deadline, while the orphaned SDK
    /// callback can finish harmlessly later.
    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let operationTask = Task<T, Error> {
            try await operation()
        }

        let gate = Insta360TimeoutResumeGate<T>()
        var timeoutTask: Task<Void, Never>?
        defer {
            operationTask.cancel()
            timeoutTask?.cancel()
        }

        return try await withUnsafeThrowingContinuation { continuation in
            timeoutTask = Task.detached {
                let ns = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                gate.resume(
                    continuation,
                    .failure(Insta360Error.commandFailed("operation timed out after \(seconds)s")))
            }

            Task.detached {
                do {
                    gate.resume(continuation, .success(try await operationTask.value))
                } catch {
                    gate.resume(continuation, .failure(error))
                }
            }
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
    public var lastKnownDeviceUUID: String? { nil }
    public var lastKnownDeviceName: String? { nil }

    public init() {}

    public static func shouldAcceptDevice(name: String?,
                                          uuid: String,
                                          excluding: Set<String>) -> Bool {
        guard isGoFamilyBLEName(name) else { return false }
        return !excluding.contains(uuid)
    }

    public static func isGoFamilyBLEName(_ name: String?) -> Bool {
        guard let normalized = normalizedMetadata(name)?.lowercased() else {
            return false
        }
        return normalized.hasPrefix("go ") || normalized.contains("insta360 go")
    }

    public static func isGo3SActionCamHost(
        cameraType: String?,
        go3Version: String?
    ) -> Bool {
        if normalizedMetadata(go3Version) != nil { return true }
        return isGo3CameraType(cameraType)
    }

    internal static func isAcceptableGo3SRecordingEndpoint(
        name: String?,
        cameraType: String?,
        go3Version: String?,
        boxVersion: String?
    ) -> Bool {
        actionCamHostDecision(
            name: name,
            cameraType: cameraType,
            go3Version: go3Version,
            boxVersion: boxVersion
        ).isAccepted
    }

    private enum ActionCamHostDecision: Equatable {
        case verified
        case provisionalMetadataUnavailable
        case rejected

        var isAccepted: Bool {
            switch self {
            case .verified, .provisionalMetadataUnavailable: return true
            case .rejected: return false
            }
        }
    }

    private static func actionCamHostDecision(
        name: String?,
        cameraType: String?,
        go3Version: String?,
        boxVersion: String?
    ) -> ActionCamHostDecision {
        if normalizedMetadata(go3Version) != nil { return .verified }
        if isGo3CameraType(cameraType) { return .verified }
        if normalizedMetadata(cameraType) != nil { return .rejected }
        if normalizedMetadata(boxVersion) != nil { return .rejected }
        if isGoFamilyBLEName(name) { return .provisionalMetadataUnavailable }
        return .rejected
    }

    private static func isGo3CameraType(_ cameraType: String?) -> Bool {
        guard let cameraType = normalizedMetadata(cameraType)?.lowercased() else {
            return false
        }
        let compact = cameraType.replacingOccurrences(of: " ", with: "")
        return compact.contains("go3")
    }

    private static func normalizedMetadata(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    internal static func encodeWakeId(serialLast6: String) -> String {
        serialLast6.unicodeScalars
            .prefix(6)
            .map { String(format: "%02X", $0.value) }
            .joined()
    }

    internal static func extractSerialLast6(fromBLEName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let token = trimmed.split(separator: " ").last.map(String.init),
              token.count == 6
        else { return nil }
        return token
    }

    internal static func broadcastWake(window _: TimeInterval = 1.5) async {}

    internal static func wake(serialLast6 _: String, window _: TimeInterval = 1.5) async {}

    internal func wakeAll(window _: TimeInterval = 1.5) async {}

    internal func wake(serialLast6 _: String, window _: TimeInterval = 1.5) async {}

    public func pair(excludingUUIDs _: Set<String> = []) async throws {
        throw Insta360Error.frameworkNotLinked
    }

    public func unpair() async throws {}

    public func syncCameraClock(dTimeMaxMs _: UInt = 2_000) async {}

    public func startRemoteRecording(clock _: SessionClock) async throws -> UInt64 {
        throw Insta360Error.frameworkNotLinked
    }

    public func stopRemoteRecording() async throws -> String {
        throw Insta360Error.frameworkNotLinked
    }

    public func wifiCredentials() async throws -> (ssid: String, passphrase: String) {
        throw Insta360Error.frameworkNotLinked
    }

    public func enableWiFiForDownload() async throws {
        throw Insta360Error.frameworkNotLinked
    }

    public func refreshConnection() async throws {
        throw Insta360Error.frameworkNotLinked
    }

    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let operationTask = Task<T, Error> {
            try await operation()
        }

        let gate = Insta360TimeoutResumeGate<T>()
        var timeoutTask: Task<Void, Never>?
        defer {
            operationTask.cancel()
            timeoutTask?.cancel()
        }

        return try await withUnsafeThrowingContinuation { continuation in
            timeoutTask = Task.detached {
                let ns = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                gate.resume(
                    continuation,
                    .failure(Insta360Error.commandFailed("operation timed out after \(seconds)s")))
            }

            Task.detached {
                do {
                    gate.resume(continuation, .success(try await operationTask.value))
                } catch {
                    gate.resume(continuation, .failure(error))
                }
            }
        }
    }
}
#endif // canImport(INSCameraServiceSDK)

extension Insta360BLEController {
    internal static func resolveDockStatus(
        chargeBoxStateRaw: UInt?,
        chargeboxUsbConnectedRaw: UInt?,
        chargeboxBtConnectedRaw: UInt?
    ) -> Insta360DockStatus {
        let noConnection: UInt = 0
        let peripheralDisconnected: UInt = 1
        let peripheralConnected: UInt = 2

        // Physical dock uses the Action Pod's USB/pogo-pin connection.
        // `state == connected` and `bt == connected` can also appear while the
        // ActionCam is separated but still wirelessly linked to the Action Pod,
        // so they are not strong enough to show a docked warning.
        if chargeboxUsbConnectedRaw == peripheralConnected {
            return .docked
        }

        if chargeboxUsbConnectedRaw == peripheralDisconnected
            || chargeBoxStateRaw == noConnection {
            return .separated
        }

        return .unknown
    }

    /// Query GO-series Action Pod dock status without making it a hard
    /// pairing precondition. Callers should treat `.unknown` as allowed and
    /// only surface guidance for `.docked`.
    public func dockStatus() async -> Insta360DockStatus {
        #if canImport(INSCameraServiceSDK)
        let deviceName = lastKnownName ?? connectedDevice?.name ?? "(unknown)"
        guard connectedDevice != nil else {
            NSLog("[Insta360BLE] dockStatus unknown device=\(deviceName) reason=notPaired")
            return .unknown
        }

        do {
            try await ensureCommandReady(
                reason: "dockStatus",
                maxCachedAgeSeconds: 5)
        } catch {
            NSLog("[Insta360BLE] dockStatus unknown device=\(deviceName) readiness=\(error.localizedDescription)")
            return .unknown
        }

        do {
            let cmd = try commandManager()
            let chargeBoxStatusType = NSNumber(value: 85) // INSCameraOptionsTypeChargeBoxStatus
            let response: (options: INSCameraOptions, successTypes: [NSNumber]) = try await Self.withTimeout(seconds: 4) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(INSCameraOptions, [NSNumber]), Error>) in
                    let sel = NSSelectorFromString("getOptionsWithTypes:completion:")
                    guard (cmd as AnyObject).responds(to: sel) else {
                        cont.resume(throwing: Insta360Error.commandFailed("BLE getOptions unavailable"))
                        return
                    }
                    let callback: @convention(block) (NSError?, INSCameraOptions?, NSArray?) -> Void = { error, options, successTypes in
                        if let error {
                            cont.resume(throwing: Insta360Error.commandFailed(error.localizedDescription))
                            return
                        }
                        if let options {
                            let successNumbers = successTypes?.compactMap { $0 as? NSNumber } ?? []
                            cont.resume(returning: (options, successNumbers))
                        } else {
                            cont.resume(throwing: Insta360Error.commandFailed("dock status unavailable"))
                        }
                    }
                    _ = (cmd as AnyObject).perform(sel, with: [chargeBoxStatusType], with: callback)
                }
            }

            let stateRaw = UInt(response.options.chargeBoxStatus.state.rawValue)
            let usbRaw = UInt(response.options.chargeBoxStatus.chargeboxUsbConnectedState.rawValue)
            let btRaw = UInt(response.options.chargeBoxStatus.chargeboxBtConnectedState.rawValue)
            let resolved = Self.resolveDockStatus(
                chargeBoxStateRaw: stateRaw,
                chargeboxUsbConnectedRaw: usbRaw,
                chargeboxBtConnectedRaw: btRaw)
            let optionConfirmed = response.successTypes.contains {
                $0.intValue == chargeBoxStatusType.intValue
            }
            let trustedStatus: Insta360DockStatus = optionConfirmed ? resolved : .unknown
            NSLog("[Insta360BLE] dockStatus device=\(deviceName) status=\(trustedStatus.rawValue) state=\(stateRaw) usb=\(usbRaw) bt=\(btRaw) optionConfirmed=\(optionConfirmed)")
            return trustedStatus
        } catch {
            NSLog("[Insta360BLE] dockStatus unknown device=\(deviceName) error=\(error.localizedDescription)")
            return .unknown
        }
        #else
        return .unknown
        #endif
    }
}
