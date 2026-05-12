import Foundation
import SyncField

#if canImport(INSCameraServiceSDK)
@preconcurrency import INSCameraServiceSDK
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
    private var scanWakeTask: Task<Void, Never>?
    private var isHardwareScanning = false
    private var pairingInProgress = false
    private var pairingWaiters: [CheckedContinuation<Void, Never>] = []
    private let keepAlive = INSAppKeepAlive()

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
        startHardwareScanIfNeeded()
        return stream
    }

    public func stopScan() async {
        stopHardwareScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    private func startHardwareScanIfNeeded() {
        guard !isHardwareScanning else { return }
        isHardwareScanning = true
        bluetoothManager.scanCameras { [weak self] device, rssi, _ in
            Task { await self?.handleScanHit(device: device, rssi: rssi.intValue) }
        }
        scanWakeTask?.cancel()
        scanWakeTask = Task {
            await Self.keepWakingDuringScan()
        }
    }

    private func stopHardwareScan() {
        if isHardwareScanning {
            bluetoothManager.stopScan()
            isHardwareScanning = false
        }
        scanWakeTask?.cancel()
        scanWakeTask = nil
        bluetoothManager.stopWakeUpAdvertising()
    }

    private func pauseHardwareScanForConnection() -> Bool {
        let shouldResume = scanContinuation != nil && isHardwareScanning
        if shouldResume {
            stopHardwareScan()
        }
        return shouldResume
    }

    private func resumeHardwareScanIfNeeded(_ shouldResume: Bool) {
        guard shouldResume, scanContinuation != nil else { return }
        startHardwareScanIfNeeded()
    }

    private static func keepWakingDuringScan() async {
        var cycle = 0
        while !Task.isCancelled {
            let records = await Insta360IdentityStore.shared.all()
            let serials = records
                .map(\.serialLast6)
                .filter { $0.count == 6 }

            if !serials.isEmpty && cycle % 3 != 2 {
                for serial in serials.prefix(4) {
                    if Task.isCancelled { return }
                    await Insta360BLEController.wake(serialLast6: serial, window: 0.45)
                }
            } else {
                await Insta360BLEController.broadcastWake(window: 0.8)
            }

            cycle += 1
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
    }

    private func handleScanHit(device: INSBluetoothDevice, rssi: Int) {
        guard Self.shouldEmitDevice(name: device.name) else { return }
        let uuid = device.identifierUUIDStringSafe
        scannedDevices[uuid] = device
        scanContinuation?.yield(DiscoveredInsta360(
            uuid: uuid, name: device.name, rssi: rssi))
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
        let identity = Insta360KnownCameraIdentity(uuid: uuid, bleName: nil)
        try await pair(identity: identity)
    }

    internal func pair(uuid: String, preferredName: String?) async throws {
        let identity = Insta360KnownCameraIdentity(uuid: uuid, bleName: preferredName)
        try await pair(identity: identity)
    }

    internal func pair(identity: Insta360KnownCameraIdentity) async throws {
        guard identity.isUsable, let bindingKey = identity.bindingKey else {
            throw Insta360Error.deviceNotDiscovered("missing saved Insta360 identity")
        }
        await acquirePairingSlot()
        defer { releasePairingSlot() }
        try await waitForBluetoothReady()
        if pairedDevices[bindingKey] != nil { return }  // idempotent
        let shouldResumeScan = pauseHardwareScanForConnection()
        defer { keepAlive.stop() }
        defer { resumeHardwareScanIfNeeded(shouldResumeScan) }

        var lastError: Error?
        for attempt in 1...3 {
            var connectedDeviceForCleanup: INSBluetoothDevice?
            do {
                let wakeTask = Task { [identity] in
                    await Self.keepWaking(identity: identity)
                }
                defer { wakeTask.cancel() }
                let device = try await connect(identity: identity, attempt: attempt)
                connectedDeviceForCleanup = device

                // Give the SDK a moment to publish the device's command
                // manager before we adopt it — shorter than 1 s caused the
                // subsequent `getCommandBy` to return nil on some devices.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                pairedDevices[bindingKey] = device
                let controller = Insta360BLEController()
                controller.adoptConnectedDevice(device)
                pairedControllers[bindingKey] = controller
                if let serial = Insta360BLEController.extractSerialLast6(fromBLEName: device.name) {
                    await Insta360IdentityStore.shared.upsert(
                        serialLast6: serial,
                        uuid: device.identifierUUIDStringSafe,
                        bleName: device.name)
                }
                if attempt > 1 {
                    NSLog("[Insta360Scanner] pair \(bindingKey) succeeded on attempt \(attempt)")
                }
                return
            } catch {
                lastError = error
                NSLog("[Insta360Scanner] pair \(bindingKey) attempt \(attempt)/3 failed: \(error.localizedDescription)")
                // Ensure any half-connected state is torn down before the
                // next attempt — lingering peripheral state is what typically
                // keeps the retry from succeeding.
                if let connectedDeviceForCleanup {
                    bluetoothManager.disconnectDevice(connectedDeviceForCleanup)
                }
                if attempt < 3 {
                    let backoffNs = UInt64(attempt) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: backoffNs)
                }
            }
        }
        throw lastError ?? Insta360Error.commandFailed("pair failed after 3 attempts")
    }

    private func connect(
        identity: Insta360KnownCameraIdentity,
        attempt: Int
    ) async throws -> INSBluetoothDevice {
        if let scanned = await resolveScannedDevice(identity: identity) {
            return try await connectScannedDevice(scanned)
        }

        if let name = identity.preferredBLEName {
            startKeepAlive(name: name)
            do {
                let timeout = attempt == 1 ? 10.0 : 8.0
                return try await Insta360BLEController.withTimeout(seconds: timeout) {
                    try await self.connectWithName(name)
                }
            } catch {
                NSLog("[Insta360Scanner] connectWithName failed name=\(name): \(error.localizedDescription)")
            }
        }

        if let uuidString = identity.uuid,
           let nsuuid = UUID(uuidString: uuidString) {
            do {
                return try await Insta360BLEController.withTimeout(seconds: 6) {
                    try await self.connectWithUUID(nsuuid)
                }
            } catch {
                NSLog("[Insta360Scanner] connectWithUUID failed uuid=\(uuidString): \(error.localizedDescription)")
            }
        }

        return try await scanAndConnect(identity: identity)
    }

    private func resolveScannedDevice(identity: Insta360KnownCameraIdentity) async -> INSBluetoothDevice? {
        guard let uuid = identity.uuid else {
            if let serial = identity.serialLast6 {
                return scannedDevices.values.first {
                    Insta360BLEController.extractSerialLast6(fromBLEName: $0.name) == serial
                }
            }
            return nil
        }

        if let device = scannedDevices[uuid] { return device }

        if let serial = identity.serialLast6,
           let match = scannedDevices.values.first(where: {
               Insta360BLEController.extractSerialLast6(fromBLEName: $0.name) == serial
           }) {
            return match
        }

        if let record = await Insta360IdentityStore.shared.record(forUUID: uuid),
           let match = scannedDevices.values.first(where: {
               Insta360BLEController.extractSerialLast6(fromBLEName: $0.name) == record.serialLast6
           }) {
            return match
        }

        return nil
    }

    private func connectScannedDevice(_ device: INSBluetoothDevice) async throws -> INSBluetoothDevice {
        try await withUnsafeThrowingContinuation {
            (cont: UnsafeContinuation<Void, Error>) in
            bluetoothManager.connect(device) { error in
                if let error = error {
                    cont.resume(throwing: Insta360Error.commandFailed(
                        error.localizedDescription))
                    return
                }
                cont.resume()
            }
        }
        return device
    }

    private func connectWithName(_ name: String) async throws -> INSBluetoothDevice {
        try await withUnsafeThrowingContinuation {
            (cont: UnsafeContinuation<INSBluetoothDevice, Error>) in
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
        try await withUnsafeThrowingContinuation {
            (cont: UnsafeContinuation<INSBluetoothDevice, Error>) in
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

    private func scanAndConnect(identity: Insta360KnownCameraIdentity) async throws -> INSBluetoothDevice {
        let manager = bluetoothManager
        defer { manager.stopScan() }
        return try await Insta360BLEController.withTimeout(seconds: 8) {
            try await withUnsafeThrowingContinuation {
                (cont: UnsafeContinuation<INSBluetoothDevice, Error>) in
                var found = false
                manager.scanCameras { device, _, _ in
                    guard !found else { return }
                    let uuidMatches = identity.uuid.map {
                        device.identifierUUIDStringSafe == $0
                    } ?? false
                    let serialMatches = identity.serialLast6.map {
                        Insta360BLEController.extractSerialLast6(fromBLEName: device.name) == $0
                    } ?? false
                    guard uuidMatches || serialMatches else { return }
                    found = true
                    manager.stopScan()
                    Task {
                        do {
                            let connected = try await self.connectScannedDevice(device)
                            cont.resume(returning: connected)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    private func startKeepAlive(name: String) {
        keepAlive.setDeviceNameMappingTable([name: name])
        keepAlive.start(withCamerName: name)
    }

    private static func keepWaking(identity: Insta360KnownCameraIdentity) async {
        var cycle = 0
        while !Task.isCancelled {
            switch Insta360WakeRetryPolicy.signal(
                serialLast6: identity.serialLast6,
                cycle: cycle
            ) {
            case .targeted(let serial):
                await Insta360BLEController.wake(serialLast6: serial, window: 0.8)
            case .broadcast:
                await Insta360BLEController.broadcastWake(window: 0.8)
            }
            cycle += 1
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    private func acquirePairingSlot() async {
        if !pairingInProgress {
            pairingInProgress = true
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pairingWaiters.append(cont)
        }
    }

    private func releasePairingSlot() {
        guard !pairingWaiters.isEmpty else {
            pairingInProgress = false
            return
        }

        let next = pairingWaiters.removeFirst()
        next.resume()
    }

    /// Pair if needed, then send the `takePicture` BLE command.
    /// The camera emits its shutter sound + LED flash — the audible cue
    /// the user matches against the physical device.
    public func identify(uuid: String) async throws {
        let shouldResumeScan = pauseHardwareScanForConnection()
        defer { resumeHardwareScanIfNeeded(shouldResumeScan) }
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
        try await bindController(identity: Insta360KnownCameraIdentity(uuid: uuid, bleName: nil))
    }

    public func bindController(
        uuid: String,
        preferredName: String?
    ) async throws -> Insta360BLEController {
        try await bindController(identity: Insta360KnownCameraIdentity(
            uuid: uuid,
            bleName: preferredName))
    }

    public func bindController(
        identity: Insta360KnownCameraIdentity
    ) async throws -> Insta360BLEController {
        guard let bindingKey = identity.bindingKey else {
            throw Insta360Error.deviceNotDiscovered("missing saved Insta360 identity")
        }
        if boundUUIDs.contains(bindingKey) {
            throw Insta360Error.uuidAlreadyBound(bindingKey)
        }
        try await pair(identity: identity)
        let controller = try controller(forUUID: bindingKey)
        boundUUIDs.insert(bindingKey)
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

    public func bindController(
        uuid _: String,
        preferredName _: String?
    ) async throws -> Insta360BLEController {
        throw Insta360Error.frameworkNotLinked
    }

    public func bindController(
        identity _: Insta360KnownCameraIdentity
    ) async throws -> Insta360BLEController {
        throw Insta360Error.frameworkNotLinked
    }

    public func releaseBinding(uuid _: String) async {}
}
#endif
