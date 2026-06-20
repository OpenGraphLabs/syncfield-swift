// Sources/SyncField/Streams/Tactile/TactileBLEClient.swift
import Foundation
#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight wrapper around CBCentralManager for a single Oglo glove.
/// Each TactileStream owns one client.
///
/// Production hardening (v2):
///  • `scan(excluding:)` skips peripheral identifiers already claimed by the other
///    glove's stream, so left/right don't race for the same device.
///  • `enableAutoReconnect` reconnects to the same peripheral (by identifier) with
///    bounded backoff after an unexpected drop and re-subscribes the notify handler,
///    emitting connection events the stream maps to HealthBus signals.
public final class TactileBLEClient: NSObject, @unchecked Sendable {
    #if canImport(CoreBluetooth)
    private let queue = DispatchQueue(label: "syncfield.tactile.ble", qos: .userInitiated)
    private lazy var central = CBCentralManager(delegate: self, queue: queue)
    private var peripheral: CBPeripheral?
    private var sensorChar: CBCharacteristic?
    private var configChar: CBCharacteristic?

    private var scanCont: CheckedContinuation<TactilePeripheralRef, Swift.Error>?
    private var connectCont: CheckedContinuation<Void, Swift.Error>?
    private var servicesCont: CheckedContinuation<Void, Swift.Error>?
    private var configCont: CheckedContinuation<Data, Swift.Error>?
    private var notifyHandler: ((Data, UInt64) -> Void)?
    private var scanExcluding: Set<UUID> = []

    // Auto-reconnect state. We NEVER give up while autoReconnect is on — BLE
    // contention from the Insta360 wrist-pairing flow (chatty wake broadcasts +
    // scans) routinely drops the OGLO link mid-setup, and it must recover on its
    // own once the radio frees up. Backoff is capped; attempts are unbounded.
    private var autoReconnect = false
    private var reconnecting = false
    private var reconnectAttempt = 0
    private var onConnectionEvent: (@Sendable (Bool, String) -> Void)?

    // Stall watchdog: notifications normally arrive ~70 Hz. If they stop for
    // longer than the threshold WITHOUT a disconnect event (silent stall under
    // radio contention), force a reconnect cycle so the link self-heals.
    private var watchdog: DispatchSourceTimer?
    private var lastNotifyAt: DispatchTime = .now()
    private let stallThresholdNs: UInt64 = 3_000_000_000   // 3 s

    // App lifecycle: iOS suspends BLE in background and connections often drop.
    // On foreground we re-evaluate the link and reconnect/re-emit (mirrors the
    // Insta360 background supervisor's foreground_resume).
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// True when the peripheral is connected and we have an active notify handler.
    public var isConnected: Bool {
        peripheral?.state == .connected && notifyHandler != nil
    }

    public enum Error: Swift.Error {
        case bluetoothUnavailable
        case scanTimeout
        case wrongSide(expected: TactileSide, actual: TactileSide)
        case disconnected(String?)
        case missingCharacteristic
        case manifestParseFailed(Swift.Error)
        case unsupportedSchema(Int)
    }
    #endif

    public override init() {
        super.init()
    }

    /// The identifier of the connected peripheral, if any (used for role claiming).
    public var peripheralIdentifier: UUID? {
        #if canImport(CoreBluetooth)
        return peripheral?.identifier
        #else
        return nil
        #endif
    }

    /// Scan for the first peripheral whose name contains "oglo" (excluding the given
    /// identifiers) and return an opaque ref. Caller identifies left/right by reading
    /// the manifest via connectAndPrepare(_:expectedSide:).
    public func scan(timeoutSeconds: TimeInterval = 15,
                     excluding: Set<UUID> = []) async throws -> TactilePeripheralRef {
        #if canImport(CoreBluetooth)
        try await waitForPoweredOn()
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<TactilePeripheralRef, Swift.Error>) in
            queue.async {
                self.scanExcluding = excluding
                self.scanCont = cont
                self.central.scanForPeripherals(withServices: nil, options: nil)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let c = self.scanCont {
                        self.scanCont = nil
                        self.central.stopScan()
                        c.resume(throwing: Error.scanTimeout)
                    }
                }
            }
        }
        #else
        throw TactileBLEClient_unavailableError()
        #endif
    }

    /// Connect to the given peripheral, discover services/characteristics, read manifest.
    /// Throws `Error.wrongSide` if the manifest's `side` doesn't match `expectedSide`.
    public func connectAndPrepare(_ ref: TactilePeripheralRef, expectedSide: TactileSide)
        async throws -> DeviceManifest
    {
        #if canImport(CoreBluetooth)
        let p = ref.peripheral
        self.peripheral = p
        p.delegate = self

        // Step 1: connect
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                self.connectCont = cont
                self.central.connect(p, options: nil)
                // CBCentralManager.connect has no timeout — it stays pending forever
                // if the peripheral is unreachable. Bound it so the background
                // acquire loop falls through to a retry instead of wedging.
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if let c = self.connectCont {
                        self.connectCont = nil
                        self.central.cancelPeripheralConnection(p)
                        c.resume(throwing: Error.disconnected("connect timeout"))
                    }
                }
            }
        }

        // Step 2: discover services + characteristics
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                self.servicesCont = cont
                p.discoverServices([CBUUID(nsuuid: TactileConstants.serviceUUID)])
            }
        }

        // Step 3: read config characteristic → raw manifest JSON
        let configData = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Data, Swift.Error>) in
            queue.async {
                guard let char = self.configChar else {
                    cont.resume(throwing: Error.missingCharacteristic); return
                }
                self.configCont = cont
                p.readValue(for: char)
            }
        }

        // Step 4: decode manifest
        let manifest: DeviceManifest
        do {
            manifest = try JSONDecoder().decode(DeviceManifest.self, from: configData)
        } catch {
            throw Error.manifestParseFailed(error)
        }

        // Step 5: validate schema. Only schema_ver 5 (packed12_v5) is supported —
        // fail clearly rather than misparse an older/newer firmware (no fallback).
        guard manifest.schemaVer == TactileConstants.schemaVer else {
            throw Error.unsupportedSchema(manifest.schemaVer)
        }

        // Step 6: validate side matches what this TactileStream was configured for
        guard manifest.side == expectedSide else {
            throw Error.wrongSide(expected: expectedSide, actual: manifest.side)
        }
        return manifest
        #else
        throw TactileBLEClient_unavailableError()
        #endif
    }

    /// Subscribe to sensor notifications. Handler receives raw packet data +
    /// host arrival time in nanoseconds (mach_absolute_time converted).
    public func subscribe(_ handler: @escaping @Sendable (Data, UInt64) -> Void) throws {
        #if canImport(CoreBluetooth)
        guard let p = peripheral, let char = sensorChar else {
            throw Error.missingCharacteristic
        }
        self.notifyHandler = handler
        queue.async {
            p.setNotifyValue(true, for: char)
            self.lastNotifyAt = .now()
            self.startWatchdog()
        }
        #else
        throw TactileBLEClient_unavailableError()
        #endif
    }

    /// Enable indefinite auto-reconnect after an unexpected drop. `onEvent(connected, reason)`
    /// fires on the BLE queue: `false` on drop, `true` after a successful resubscribe.
    public func enableAutoReconnect(_ onEvent: @escaping @Sendable (Bool, String) -> Void) {
        #if canImport(CoreBluetooth)
        queue.async {
            self.autoReconnect = true
            self.onConnectionEvent = onEvent
        }
        startLifecycleObservers()
        #endif
    }

    /// Re-publish the current connection state (and reconnect if dropped). Called
    /// when the UI re-mounts (screen navigation) so it reflects reality instead
    /// of a stale "unknown/white" row even when no transition event fired.
    public func reemitState() {
        #if canImport(CoreBluetooth)
        queue.async {
            guard self.notifyHandler != nil else { return }  // never connected yet
            if self.isConnected {
                self.lastNotifyAt = .now()
                self.onConnectionEvent?(true, "refresh")
            } else if self.autoReconnect, !self.reconnecting {
                self.scheduleReconnect(reason: "refresh_disconnected")
            }
        }
        #endif
    }

    /// Unsubscribe and cancel the peripheral connection. Disables auto-reconnect.
    public func disconnect() {
        #if canImport(CoreBluetooth)
        stopLifecycleObservers()
        queue.async {
            self.autoReconnect = false
            self.reconnecting = false
            self.stopWatchdog()
            if let p = self.peripheral {
                if let char = self.sensorChar { p.setNotifyValue(false, for: char) }
                self.central.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
            self.sensorChar = nil
            self.configChar = nil
            self.notifyHandler = nil
        }
        #endif
    }

    #if canImport(CoreBluetooth)
    private func waitForPoweredOn() async throws {
        // Kick lazy initialisation so the CBCentralManager is created before we poll.
        _ = central
        for _ in 0..<50 {  // up to 5 s, polling every 100 ms
            if central.state == .poweredOn { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Error.bluetoothUnavailable
    }

    /// Begin an indefinite reconnect to the last peripheral. Runs on `queue`.
    private func scheduleReconnect(reason: String) {
        guard autoReconnect, let p = peripheral, !reconnecting else { return }
        reconnecting = true
        reconnectAttempt = 0
        onConnectionEvent?(false, reason)
        attemptReconnect(p)
    }

    private func attemptReconnect(_ p: CBPeripheral) {
        guard autoReconnect, reconnecting else { return }
        reconnectAttempt += 1
        // NEVER give up while the session wants this glove. Backoff is capped at
        // 5 s; once the radio frees up (Insta360 pairing settles) CoreBluetooth's
        // pending connect resolves and didConnect drives re-subscribe.
        let backoff = min(0.5 * Double(reconnectAttempt), 5.0)
        queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, self.autoReconnect, self.reconnecting else { return }
            // Re-resolve the peripheral handle so a stale reference doesn't wedge us.
            let target = self.central.retrievePeripherals(withIdentifiers: [p.identifier]).first ?? p
            self.peripheral = target
            target.delegate = self
            self.central.connect(target, options: nil)
        }
    }

    // MARK: Stall watchdog

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.autoReconnect, !self.reconnecting,
                  self.notifyHandler != nil, let p = self.peripheral else { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- self.lastNotifyAt.uptimeNanoseconds
            if elapsed > self.stallThresholdNs {
                // Notifications stopped without a disconnect event. Cancel the
                // (silently stalled) link; didDisconnectPeripheral then drives the
                // normal indefinite-reconnect path.
                NSLog("[Tactile] stall watchdog: no notify for \(elapsed / 1_000_000)ms — forcing reconnect")
                self.central.cancelPeripheralConnection(p)
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: App lifecycle

    private func startLifecycleObservers() {
        #if canImport(UIKit)
        guard lifecycleObservers.isEmpty else { return }
        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.handleForeground() }
        let active = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.handleForeground() }
        lifecycleObservers = [fg, active]
        #endif
    }

    private func stopLifecycleObservers() {
        for o in lifecycleObservers { NotificationCenter.default.removeObserver(o) }
        lifecycleObservers = []
    }

    /// On returning to foreground, iOS may have torn the BLE link down while
    /// suspended. Re-establish if needed; otherwise re-emit "connected" so the
    /// UI is accurate. Mirrors Insta360's foreground_resume → reconnect path.
    private func handleForeground() {
        queue.async { [weak self] in
            guard let self, self.autoReconnect, self.notifyHandler != nil else { return }
            if self.isConnected {
                self.lastNotifyAt = .now()
                self.onConnectionEvent?(true, "foreground")
            } else if !self.reconnecting {
                self.scheduleReconnect(reason: "foreground_resume")
            }
        }
    }
    #endif
}

/// Opaque reference to a scanned CBPeripheral.
public struct TactilePeripheralRef: @unchecked Sendable {
    #if canImport(CoreBluetooth)
    internal let peripheral: CBPeripheral
    public let identifier: UUID
    internal init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        self.identifier = peripheral.identifier
    }
    #endif
}

#if canImport(CoreBluetooth)
extension TactileBLEClient: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // State changes are polled in waitForPoweredOn(); no action needed here.
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (peripheral.name ?? "").lowercased()
        guard name.contains(TactileConstants.nameFilter) else { return }
        guard !scanExcluding.contains(peripheral.identifier) else { return }
        if let cont = scanCont {
            scanCont = nil
            central.stopScan()
            cont.resume(returning: TactilePeripheralRef(peripheral: peripheral))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        if let cont = connectCont { connectCont = nil; cont.resume(returning: ()); return }
        // Reconnect path: rediscover services to rebuild characteristic handles.
        if reconnecting {
            peripheral.delegate = self
            peripheral.discoverServices([CBUUID(nsuuid: TactileConstants.serviceUUID)])
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Swift.Error?) {
        if let cont = connectCont {
            connectCont = nil
            cont.resume(throwing: Error.disconnected(error?.localizedDescription))
            return
        }
        if reconnecting { attemptReconnect(peripheral) }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Swift.Error?) {
        sensorChar = nil
        configChar = nil
        // Unexpected drop while we want to stay connected → reconnect; else clean up.
        if autoReconnect {
            scheduleReconnect(reason: error?.localizedDescription ?? "disconnected")
        } else {
            notifyHandler = nil
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: Swift.Error?) {
        guard let svc = peripheral.services?.first(where: {
            $0.uuid == CBUUID(nsuuid: TactileConstants.serviceUUID)
        }) else {
            if let cont = servicesCont {
                servicesCont = nil
                cont.resume(throwing: Error.missingCharacteristic)
            } else if reconnecting {
                attemptReconnect(peripheral)
            }
            return
        }
        peripheral.discoverCharacteristics(
            [CBUUID(nsuuid: TactileConstants.sensorCharUUID),
             CBUUID(nsuuid: TactileConstants.configCharUUID)],
            for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Swift.Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == CBUUID(nsuuid: TactileConstants.sensorCharUUID) { sensorChar = char }
            if char.uuid == CBUUID(nsuuid: TactileConstants.configCharUUID) { configChar = char }
        }
        if let cont = servicesCont { servicesCont = nil; cont.resume(returning: ()); return }
        // Reconnect path: resubscribe and report recovery.
        if reconnecting {
            reconnecting = false
            reconnectAttempt = 0
            if let char = sensorChar { peripheral.setNotifyValue(true, for: char) }
            lastNotifyAt = .now()   // reset the stall watchdog baseline
            onConnectionEvent?(true, "reconnected")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Swift.Error?) {
        // Config read response → resume the manifest continuation
        if characteristic.uuid == CBUUID(nsuuid: TactileConstants.configCharUUID),
           let data = characteristic.value,
           let cont = configCont {
            configCont = nil
            cont.resume(returning: data)
            return
        }
        // Sensor notify → forward to the registered packet handler with host timestamp
        if characteristic.uuid == CBUUID(nsuuid: TactileConstants.sensorCharUUID),
           let data = characteristic.value,
           let handler = notifyHandler {
            lastNotifyAt = .now()   // feed the stall watchdog
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let arrivalNs = mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom)
            handler(data, arrivalNs)
        }
    }
}
#endif

// MARK: - Platform stub

/// Thrown on platforms where CoreBluetooth is unavailable.
private struct TactileBLEClient_unavailableError: Swift.Error {}
