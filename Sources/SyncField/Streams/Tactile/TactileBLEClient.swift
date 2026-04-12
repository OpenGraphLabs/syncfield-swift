// Sources/SyncField/Streams/Tactile/TactileBLEClient.swift
import Foundation
#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

/// Lightweight wrapper around CBCentralManager for a single Oglo glove.
/// Each TactileStream owns one client.
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

    public enum Error: Swift.Error {
        case bluetoothUnavailable
        case scanTimeout
        case wrongSide(expected: TactileSide, actual: TactileSide)
        case disconnected(String?)
        case missingCharacteristic
        case manifestParseFailed(Swift.Error)
    }
    #endif

    public override init() {
        super.init()
    }

    /// Scan for the first peripheral whose name contains "oglo" and returns an opaque ref.
    /// Caller identifies left/right by reading the manifest via connectAndPrepare(_:expectedSide:).
    public func scan(timeoutSeconds: TimeInterval = 15) async throws -> TactilePeripheralRef {
        #if canImport(CoreBluetooth)
        try await waitForPoweredOn()
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<TactilePeripheralRef, Swift.Error>) in
            queue.async {
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

        // Step 5: validate side matches what this TactileStream was configured for
        guard manifest.side == expectedSide else {
            throw Error.wrongSide(expected: expectedSide, actual: manifest.side)
        }
        return manifest
        #else
        throw TactileBLEClient_unavailableError()
        #endif
    }

    /// Subscribe to FSR sensor notifications. Handler receives raw packet data +
    /// host arrival time in nanoseconds (mach_absolute_time converted).
    public func subscribe(_ handler: @escaping @Sendable (Data, UInt64) -> Void) throws {
        #if canImport(CoreBluetooth)
        guard let p = peripheral, let char = sensorChar else {
            throw Error.missingCharacteristic
        }
        self.notifyHandler = handler
        queue.async { p.setNotifyValue(true, for: char) }
        #else
        throw TactileBLEClient_unavailableError()
        #endif
    }

    /// Unsubscribe and cancel the peripheral connection.
    public func disconnect() {
        #if canImport(CoreBluetooth)
        if let p = peripheral {
            if let char = sensorChar { p.setNotifyValue(false, for: char) }
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        sensorChar = nil
        configChar = nil
        notifyHandler = nil
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
    #endif
}

/// Opaque reference to a scanned CBPeripheral.
/// Instances are used only as an internal handoff between scan() and connectAndPrepare()
/// on the same TactileBLEClient — not for customer use.
/// @unchecked Sendable: CBPeripheral itself is not Sendable, but the ref crosses
/// only between the two async calls on the same client/queue.
public struct TactilePeripheralRef: @unchecked Sendable {
    #if canImport(CoreBluetooth)
    internal let peripheral: CBPeripheral
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
        if let cont = scanCont {
            scanCont = nil
            central.stopScan()
            cont.resume(returning: TactilePeripheralRef(peripheral: peripheral))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        if let cont = connectCont { connectCont = nil; cont.resume(returning: ()) }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Swift.Error?) {
        notifyHandler = nil
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: Swift.Error?) {
        guard let svc = peripheral.services?.first(where: {
            $0.uuid == CBUUID(nsuuid: TactileConstants.serviceUUID)
        }) else {
            servicesCont?.resume(throwing: Error.missingCharacteristic)
            servicesCont = nil; return
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
        if let cont = servicesCont { servicesCont = nil; cont.resume(returning: ()) }
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
/// Defined outside the #if block so it can be referenced regardless of platform.
private struct TactileBLEClient_unavailableError: Swift.Error {}
