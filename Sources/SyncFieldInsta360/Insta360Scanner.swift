import Foundation
import SyncField

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK
#endif

/// Snapshot of a BLE-discovered Insta360 camera.
public struct DiscoveredInsta360: Sendable, Equatable {
    public let uuid: String
    public let name: String
    public let rssi: Int

    public init(uuid: String, name: String, rssi: Int) {
        self.uuid = uuid; self.name = name; self.rssi = rssi
    }
}

#if canImport(INSCameraServiceSDK)
/// Process-wide scanner and pairing coordinator for multi-camera Insta360 BLE operations.
///
/// Hosts use this actor to discover nearby Go-family cameras, trigger the
/// identify cue on a specific UUID, and let `Insta360CameraStream(streamId:uuid:)`
/// adopt the pre-paired controller during `connect()`.
public actor Insta360Scanner {
    public static let shared = Insta360Scanner()

    /// Shared with every `Insta360BLEController` — a peripheral connected
    /// through this manager is usable from any controller in the process.
    /// See `Insta360BLEController.sharedManager` for the rationale.
    private var bluetoothManager: INSBluetoothManager {
        Insta360BLEController.sharedManager
    }
    private var scannedDevices: [String: INSBluetoothDevice] = [:]
    private var pairedDevices: [String: INSBluetoothDevice] = [:]
    private var pairedControllers: [String: Insta360BLEController] = [:]
    private var boundUUIDs: Set<String> = []
    private var scanContinuation: AsyncStream<DiscoveredInsta360>.Continuation?

    private init() {
        INSCameraManager.shared().setup()
    }

    // MARK: - Pure helpers (unit-tested)

    /// Accept predicate for scan callbacks. Accepts iff name contains
    /// "go" case-insensitively. UUID exclusion is handled at a higher layer
    /// (the UI passes already-paired UUIDs to filter out).
    public static func shouldEmitDevice(name: String?) -> Bool {
        guard let name = name else { return false }
        return name.lowercased().contains("go")
    }

    // MARK: - Scanning

    /// Start a streaming BLE scan. Returns an `AsyncStream`
    /// that yields each discovered Go-family camera. Multiple subscribers
    /// are NOT supported — this is a single-consumer stream.
    public func scan() async throws -> AsyncStream<DiscoveredInsta360> {
        if scanContinuation != nil { throw Insta360Error.scanAlreadyActive }
        try await waitForBluetoothReady()

        let stream = AsyncStream(DiscoveredInsta360.self,
                                  bufferingPolicy: .bufferingNewest(32)) { cont in
            self.scanContinuation = cont
        }
        bluetoothManager.scanCameras { [weak self] device, rssi, _ in
            Task { await self?.handleScanHit(device: device, rssi: rssi.intValue) }
        }
        return stream
    }

    public func stopScan() async {
        bluetoothManager.stopScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    private func handleScanHit(device: INSBluetoothDevice, rssi: Int) {
        guard Self.shouldEmitDevice(name: device.name) else { return }
        let uuid = device.identifierUUIDStringSafe
        scannedDevices[uuid] = device
        scanContinuation?.yield(DiscoveredInsta360(
            uuid: uuid, name: device.name ?? "", rssi: rssi))
    }

    // MARK: - Pair / Unpair

    /// Pair with the camera identified by `uuid`. The device must be in the recent scan set.
    ///
    /// Retries up to 3 attempts with 1 s / 2 s backoff. `INSBluetoothManager`
    /// occasionally fails the first `connect` with a transient CoreBluetooth
    /// error when multiple peripherals advertise near the device (common
    /// with 3 Insta360 cameras in the same room), and a retry almost always
    /// succeeds. Previous single-attempt behaviour was the main source of
    /// "BLE 연결 오래 걸리거나 실패" reports.
    public func pair(uuid: String) async throws {
        if pairedDevices[uuid] != nil { return }  // idempotent
        guard let device = scannedDevices[uuid] else {
            throw Insta360Error.deviceNotDiscovered(uuid)
        }

        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await withCheckedThrowingContinuation {
                    (cont: CheckedContinuation<Void, Error>) in
                    bluetoothManager.connect(device) { error in
                        if let error = error {
                            cont.resume(throwing: Insta360Error.commandFailed(
                                error.localizedDescription))
                            return
                        }
                        cont.resume()
                    }
                }
                // Give the SDK a moment to publish the device's command
                // manager before we adopt it — shorter than 1 s caused the
                // subsequent `getCommandBy` to return nil on some devices.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                pairedDevices[uuid] = device
                let controller = Insta360BLEController()
                controller.adoptConnectedDevice(device)
                pairedControllers[uuid] = controller
                if attempt > 1 {
                    NSLog("[Insta360Scanner] pair \(uuid) succeeded on attempt \(attempt)")
                }
                return
            } catch {
                lastError = error
                NSLog("[Insta360Scanner] pair \(uuid) attempt \(attempt)/3 failed: \(error.localizedDescription)")
                // Ensure any half-connected state is torn down before the
                // next attempt — lingering peripheral state is what typically
                // keeps the retry from succeeding.
                bluetoothManager.disconnectDevice(device)
                if attempt < 3 {
                    let backoffNs = UInt64(attempt) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: backoffNs)
                }
            }
        }
        throw lastError ?? Insta360Error.commandFailed("pair failed after 3 attempts")
    }

    /// Pair if needed, then send the `takePicture` BLE command.
    /// The camera emits its shutter sound + LED flash — the audible cue
    /// the user matches against the physical device.
    public func identify(uuid: String) async throws {
        try await pair(uuid: uuid)
        guard let device = pairedDevices[uuid] else {
            throw Insta360Error.deviceNotPaired(uuid)
        }
        guard let cmd = bluetoothManager.getCommandBy(device) as? INSCameraBasicCommands else {
            throw Insta360Error.commandFailed("command manager unavailable")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cmd.takePicture(with: nil) { error, _ in
                if let error = error {
                    cont.resume(throwing: Insta360Error.identifyPhotoFailed(
                        error.localizedDescription))
                    return
                }
                cont.resume()
            }
        }
    }

    public func unpair(uuid: String) async throws {
        guard let device = pairedDevices[uuid] else { return }
        try? await pairedControllers[uuid]?.unpair()
        bluetoothManager.disconnectDevice(device)
        pairedDevices[uuid] = nil
        pairedControllers[uuid] = nil
        boundUUIDs.remove(uuid)
    }

    public func unpairAll() async throws {
        for uuid in Array(pairedDevices.keys) {
            try? await unpair(uuid: uuid)
        }
    }

    public func pairedUUIDs() -> Set<String> {
        Set(pairedDevices.keys)
    }

    public func controller(forUUID uuid: String) throws -> Insta360BLEController {
        guard let c = pairedControllers[uuid] else {
            throw Insta360Error.deviceNotPaired(uuid)
        }
        return c
    }

    /// Reserve a paired controller for a UUID-bound stream.
    ///
    /// The same physical camera cannot be bound to two streams at once.
    /// `releaseBinding(uuid:)` is called by the stream on disconnect.
    public func bindController(uuid: String) async throws -> Insta360BLEController {
        if boundUUIDs.contains(uuid) {
            throw Insta360Error.uuidAlreadyBound(uuid)
        }
        try await pair(uuid: uuid)
        let controller = try controller(forUUID: uuid)
        boundUUIDs.insert(uuid)
        return controller
    }

    public func releaseBinding(uuid: String) async {
        boundUUIDs.remove(uuid)
    }

    // MARK: - Helpers

    /// Wait up to 5 seconds for CoreBluetooth state to become `.ready`.
    /// `INSBluetoothManager` is initialised lazily at first `Insta360Scanner.shared`
    /// access, and CoreBluetooth central-manager state transitions take ~1-2 s
    /// after creation — this poll loop matches the pattern used by the
    /// single-device `Insta360BLEController.pair()` so behaviour is consistent.
    private func waitForBluetoothReady() async throws {
        for _ in 0..<50 {
            if bluetoothManager.state == .ready { return }
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        throw Insta360Error.commandFailed("Bluetooth not ready")
    }
}
#else
/// Simulator/test fallback used when the proprietary Insta360 SDK slice is
/// unavailable. Keeps the bridge buildable while every SDK-backed operation
/// still fails explicitly at runtime.
public actor Insta360Scanner {
    public static let shared = Insta360Scanner()

    private init() {}

    public static func shouldEmitDevice(name: String?) -> Bool {
        guard let name = name else { return false }
        return name.lowercased().contains("go")
    }

    public func scan() async throws -> AsyncStream<DiscoveredInsta360> {
        throw Insta360Error.frameworkNotLinked
    }

    public func stopScan() async {}

    public func pair(uuid _: String) async throws {
        throw Insta360Error.frameworkNotLinked
    }

    public func identify(uuid _: String) async throws {
        throw Insta360Error.frameworkNotLinked
    }

    public func unpair(uuid _: String) async throws {}

    public func unpairAll() async throws {}

    public func pairedUUIDs() -> Set<String> {
        []
    }

    public func controller(forUUID _: String) throws -> Insta360BLEController {
        throw Insta360Error.frameworkNotLinked
    }

    public func bindController(uuid _: String) async throws -> Insta360BLEController {
        throw Insta360Error.frameworkNotLinked
    }

    public func releaseBinding(uuid _: String) async {}
}
#endif
