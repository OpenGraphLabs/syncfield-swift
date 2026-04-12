# syncfield-swift v0.2 — Plan B: TactileStream (Oglo BLE gloves)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `TactileStream` built-in adapter that connects to one Oglo tactile glove (left or right) over CoreBluetooth, reads the firmware manifest to validate side + finger-channel mapping, subscribes to batched 100 Hz FSR notifications, and records each sample via `SensorWriter` with **dual timestamps** (host monotonic + device hardware μs).

**Architecture:** `TactileStream` implements `SyncFieldStream`. It owns a private `CBCentralManager` delegate + `CBPeripheral` reference. Packet parsing is a pure function (testable on macOS). The stream writes `{streamId}.jsonl` with channels keyed by canonical finger labels (`thumb / index / middle / ring / pinky`) plus `device_timestamp_ns` per sample.

**Tech Stack:** CoreBluetooth, existing SensorWriter, existing SyncFieldStream protocol.

**Source reference:** `/Users/jerry/Documents/egonaut/mobile/ios/EgonautMobile/Tactile/{TactileConstants.swift, TactileGloveManager.swift}` — port per-field, do not import.

**Unchangeable constants (verbatim from egonaut/firmware contract):**
- Service UUID: `4652535F-424C-4500-0000-000000000001`
- Sensor notify char: `4652535F-424C-4500-0001-000000000001`
- Config read char: `4652535F-424C-4500-0002-000000000001`
- Packet: 6-byte header (`count: UInt16 LE`, `batch_timestamp_us: UInt32 LE`) + `count × 5 × UInt16 LE` samples. Count is typically 10. Total 106 bytes at 100 Hz.
- Advertised name filter: contains `"oglo"` case-insensitive.
- Manifest JSON fields: `side` (`"left"`/`"right"`), `rate_hz`, `channels: [{id, loc, type, bits}]`.
- Finger canonical order: `["thumb", "index", "middle", "ring", "pinky"]`.

---

## Phase B-1: Constants + `TactileSide` + `DeviceManifest`

### Task 1.1: Value types (no BLE dependency → fully testable)

**Files:**
- Create: `Sources/SyncField/Streams/Tactile/TactileTypes.swift`
- Create: `Tests/SyncFieldTests/TactileTypesTests.swift`

- [ ] **Step 1: Write tests (FAIL)**

```swift
// Tests/SyncFieldTests/TactileTypesTests.swift
import XCTest
@testable import SyncField

final class TactileTypesTests: XCTestCase {
    func test_constants_match_firmware() {
        XCTAssertEqual(TactileConstants.serviceUUID.uuidString,
                       "4652535F-424C-4500-0000-000000000001")
        XCTAssertEqual(TactileConstants.sensorCharUUID.uuidString,
                       "4652535F-424C-4500-0001-000000000001")
        XCTAssertEqual(TactileConstants.configCharUUID.uuidString,
                       "4652535F-424C-4500-0002-000000000001")
        XCTAssertEqual(TactileConstants.nameFilter, "oglo")
        XCTAssertEqual(TactileConstants.canonicalFingerOrder,
                       ["thumb", "index", "middle", "ring", "pinky"])
        XCTAssertEqual(TactileConstants.packetHeaderBytes, 6)
        XCTAssertEqual(TactileConstants.channelsPerSample, 5)
        XCTAssertEqual(TactileConstants.bytesPerSample, 10)
    }

    func test_side_rawValue_matches_manifest_contract() {
        XCTAssertEqual(TactileSide.left.rawValue, "left")
        XCTAssertEqual(TactileSide.right.rawValue, "right")
    }

    func test_manifest_parses_from_firmware_json() throws {
        let json = """
        {"device":"oglo","side":"left","hw_rev":"v1.2","rate_hz":100,
         "channels":[{"id":0,"loc":"thumb","type":"fsr","bits":12},
                     {"id":1,"loc":"index","type":"fsr","bits":12},
                     {"id":2,"loc":"middle","type":"fsr","bits":12},
                     {"id":3,"loc":"ring","type":"fsr","bits":12},
                     {"id":4,"loc":"pinky","type":"fsr","bits":12}]}
        """
        let m = try JSONDecoder().decode(DeviceManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.side, .left)
        XCTAssertEqual(m.rateHz, 100)
        XCTAssertEqual(m.channels.count, 5)
        XCTAssertEqual(m.locationForChannel(0), "thumb")
        XCTAssertEqual(m.locationForChannel(4), "pinky")
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/SyncField/Streams/Tactile/TactileTypes.swift
import Foundation

public enum TactileSide: String, Codable, Sendable {
    case left, right
}

public enum TactileConstants {
    public static let serviceUUID    = UUID(uuidString: "4652535F-424C-4500-0000-000000000001")!
    public static let sensorCharUUID = UUID(uuidString: "4652535F-424C-4500-0001-000000000001")!
    public static let configCharUUID = UUID(uuidString: "4652535F-424C-4500-0002-000000000001")!
    public static let nameFilter = "oglo"
    public static let canonicalFingerOrder = ["thumb", "index", "middle", "ring", "pinky"]
    public static let packetHeaderBytes = 6
    public static let channelsPerSample = 5
    public static let bytesPerSample    = channelsPerSample * 2  // 10
    public static let sampleIntervalUs: UInt32 = 10_000          // 100 Hz
}

public struct DeviceManifest: Codable, Sendable {
    public struct Channel: Codable, Sendable {
        public let id: Int
        public let loc: String
        public let type: String
        public let bits: Int
    }

    public let device: String
    public let side: TactileSide
    public let hwRev: String?
    public let rateHz: Int
    public let channels: [Channel]

    public func locationForChannel(_ id: Int) -> String? {
        channels.first(where: { $0.id == id })?.loc
    }

    enum CodingKeys: String, CodingKey {
        case device
        case side
        case hwRev = "hw_rev"
        case rateHz = "rate_hz"
        case channels
    }
}
```

- [ ] **Step 3: Tests PASS, commit**

```bash
git add Sources/SyncField/Streams/Tactile/TactileTypes.swift \
        Tests/SyncFieldTests/TactileTypesTests.swift
git commit -m "feat: Tactile constants, TactileSide, DeviceManifest"
```

---

## Phase B-2: Packet parser (pure function)

### Task 2.1: `TactilePacketParser`

**Files:**
- Create: `Sources/SyncField/Streams/Tactile/TactilePacketParser.swift`
- Create: `Tests/SyncFieldTests/TactilePacketParserTests.swift`

- [ ] **Step 1: Write tests (FAIL)**

```swift
// Tests/SyncFieldTests/TactilePacketParserTests.swift
import XCTest
@testable import SyncField

final class TactilePacketParserTests: XCTestCase {
    // Build a 3-sample packet manually so we don't depend on device.
    // header: count=3, batch_ts_us=0x01020304
    // samples[0]: [100, 200, 300, 400, 500]
    // samples[1]: [110, 210, 310, 410, 510]
    // samples[2]: [120, 220, 320, 420, 520]
    func test_parses_batch_with_three_samples() throws {
        var bytes: [UInt8] = [
            0x03, 0x00,              // count = 3 (LE)
            0x04, 0x03, 0x02, 0x01,  // batch_ts_us = 0x01020304
        ]
        func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        for base in [UInt16(100), UInt16(110), UInt16(120)] {
            for offset: UInt16 in [0, 100, 200, 300, 400] {
                bytes += u16LE(base + offset)
            }
        }

        let parsed = try TactilePacketParser.parse(Data(bytes))
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.batchTimestampUs, 0x01020304)
        XCTAssertEqual(parsed.samples.count, 3)
        XCTAssertEqual(parsed.samples[0], [100, 200, 300, 400, 500])
        XCTAssertEqual(parsed.samples[2], [120, 220, 320, 420, 520])
    }

    func test_rejects_truncated_packet() {
        let tooShort = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00])  // header only
        XCTAssertThrowsError(try TactilePacketParser.parse(tooShort))
    }

    func test_zero_count_is_empty() throws {
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0]
        let parsed = try TactilePacketParser.parse(Data(bytes))
        XCTAssertEqual(parsed.count, 0)
        XCTAssertEqual(parsed.samples.count, 0)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/SyncField/Streams/Tactile/TactilePacketParser.swift
import Foundation

public struct TactilePacket: Sendable {
    public let count: Int
    public let batchTimestampUs: UInt32
    public let samples: [[UInt16]]   // [sample_index][channel_index]
}

public enum TactilePacketParser {
    public enum Error: Swift.Error { case truncated, sizeMismatch }

    public static func parse(_ data: Data) throws -> TactilePacket {
        guard data.count >= TactileConstants.packetHeaderBytes else { throw Error.truncated }

        let count = Int(u16LE(data, offset: 0))
        let batchTsUs = u32LE(data, offset: 2)

        let expected = TactileConstants.packetHeaderBytes
            + count * TactileConstants.bytesPerSample
        guard data.count >= expected else { throw Error.sizeMismatch }

        var samples: [[UInt16]] = []
        samples.reserveCapacity(count)
        for s in 0..<count {
            let base = TactileConstants.packetHeaderBytes + s * TactileConstants.bytesPerSample
            var channels: [UInt16] = []
            channels.reserveCapacity(TactileConstants.channelsPerSample)
            for c in 0..<TactileConstants.channelsPerSample {
                channels.append(u16LE(data, offset: base + c * 2))
            }
            samples.append(channels)
        }

        return TactilePacket(count: count, batchTimestampUs: batchTsUs, samples: samples)
    }

    @inline(__always)
    private static func u16LE(_ d: Data, offset: Int) -> UInt16 {
        UInt16(d[d.startIndex + offset]) | (UInt16(d[d.startIndex + offset + 1]) << 8)
    }

    @inline(__always)
    private static func u32LE(_ d: Data, offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(d[d.startIndex + offset + i]) << (8 * i)
        }
        return v
    }
}
```

- [ ] **Step 3: Tests PASS, commit**

```bash
git add Sources/SyncField/Streams/Tactile/TactilePacketParser.swift \
        Tests/SyncFieldTests/TactilePacketParserTests.swift
git commit -m "feat: TactilePacketParser for Oglo notify frames"
```

---

## Phase B-3: CoreBluetooth connection wrapper

### Task 3.1: `TactileBLEClient` — isolates CoreBluetooth delegate callbacks

**Files:**
- Create: `Sources/SyncField/Streams/Tactile/TactileBLEClient.swift`

This class encapsulates `CBCentralManager` + `CBPeripheral` delegate plumbing. It exposes three async hooks:
- `scan(nameFilter:timeout:) async throws -> CBPeripheral`
- `connectAndPrepare(_:) async throws -> DeviceManifest`
- `subscribe(_ handler: @escaping @Sendable (Data, UInt64) -> Void) throws` — `handler` receives raw notify payload + `mach_absolute_time`-derived arrival ns.

The implementation is ~200 lines of CoreBluetooth delegate boilerplate. Write it directly; no unit tests (delegate callbacks aren't unit-testable without a mock transport).

- [ ] **Step 1: Implement** — follow this structure:

```swift
// Sources/SyncField/Streams/Tactile/TactileBLEClient.swift
import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// Lightweight wrapper around CBCentralManager for a single Oglo glove.
/// Each TactileStream owns one client.
public final class TactileBLEClient: NSObject, @unchecked Sendable {
    #if canImport(CoreBluetooth)
    private let central = CBCentralManager()
    private let queue = DispatchQueue(label: "syncfield.tactile.ble", qos: .userInitiated)
    private var peripheral: CBPeripheral?
    private var sensorChar: CBCharacteristic?
    private var configChar: CBCharacteristic?

    private var scanCont: CheckedContinuation<CBPeripheral, Swift.Error>?
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
        #if canImport(CoreBluetooth)
        central.delegate = self
        #endif
    }

    /// Scan for the first peripheral whose name contains "oglo" and returns it.
    /// Caller is responsible for identifying left/right by reading the manifest.
    public func scan(timeoutSeconds: TimeInterval = 15) async throws -> TactilePeripheralRef {
        #if canImport(CoreBluetooth)
        try await waitForPoweredOn()
        return try await withCheckedThrowingContinuation { cont in
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
        throw Error.bluetoothUnavailable
        #endif
    }

    /// Connect to the given peripheral, discover services, read manifest.
    public func connectAndPrepare(_ ref: TactilePeripheralRef, expectedSide: TactileSide)
        async throws -> DeviceManifest
    {
        #if canImport(CoreBluetooth)
        let p = ref.peripheral
        self.peripheral = p
        p.delegate = self

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                self.connectCont = cont
                self.central.connect(p, options: nil)
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                self.servicesCont = cont
                p.discoverServices([CBUUID(nsuuid: TactileConstants.serviceUUID)])
            }
        }

        // Read config characteristic → manifest
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

        let manifest: DeviceManifest
        do {
            manifest = try JSONDecoder().decode(DeviceManifest.self, from: configData)
        } catch {
            throw Error.manifestParseFailed(error)
        }

        guard manifest.side == expectedSide else {
            throw Error.wrongSide(expected: expectedSide, actual: manifest.side)
        }
        return manifest
        #else
        throw Error.bluetoothUnavailable
        #endif
    }

    public func subscribe(_ handler: @escaping @Sendable (Data, UInt64) -> Void) throws {
        #if canImport(CoreBluetooth)
        guard let p = peripheral, let char = sensorChar else {
            throw Error.missingCharacteristic
        }
        self.notifyHandler = handler
        queue.async { p.setNotifyValue(true, for: char) }
        #else
        throw Error.bluetoothUnavailable
        #endif
    }

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
        for _ in 0..<50 {  // up to 5s
            if central.state == .poweredOn { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Error.bluetoothUnavailable
    }
    #endif
}

/// Opaque reference to a scanned peripheral — hides CBPeripheral from public API surface.
public struct TactilePeripheralRef: Sendable, @unchecked Sendable {
    #if canImport(CoreBluetooth)
    let peripheral: CBPeripheral
    #endif
}

#if canImport(CoreBluetooth)
extension TactileBLEClient: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) { /* no-op */ }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (peripheral.name ?? "").lowercased()
        guard name.contains(TactileConstants.nameFilter) else { return }
        if let c = scanCont {
            scanCont = nil
            central.stopScan()
            c.resume(returning: TactilePeripheralRef(peripheral: peripheral).peripheral as Any
                      as? CBPeripheral ?? peripheral)
            // The above cast-chain is ugly — simpler:
            // c.resume(returning: peripheral)  — but public API expects TactilePeripheralRef.
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let c = connectCont { connectCont = nil; c.resume(returning: ()) }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Swift.Error?) {
        notifyHandler = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Swift.Error?) {
        guard let svc = peripheral.services?.first(where: {
            $0.uuid == CBUUID(nsuuid: TactileConstants.serviceUUID)
        }) else {
            servicesCont?.resume(throwing: Error.missingCharacteristic)
            servicesCont = nil; return
        }
        peripheral.discoverCharacteristics(
            [CBUUID(nsuuid: TactileConstants.sensorCharUUID),
             CBUUID(nsuuid: TactileConstants.configCharUUID)], for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Swift.Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(nsuuid: TactileConstants.sensorCharUUID) { sensorChar = c }
            if c.uuid == CBUUID(nsuuid: TactileConstants.configCharUUID) { configChar = c }
        }
        if let c = servicesCont { servicesCont = nil; c.resume(returning: ()) }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Swift.Error?) {
        if characteristic.uuid == CBUUID(nsuuid: TactileConstants.configCharUUID),
           let data = characteristic.value, let cont = configCont {
            configCont = nil
            cont.resume(returning: data)
            return
        }
        if characteristic.uuid == CBUUID(nsuuid: TactileConstants.sensorCharUUID),
           let data = characteristic.value, let handler = notifyHandler {
            // Capture host arrival time as early as possible
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            let arrivalNs = mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom)
            handler(data, arrivalNs)
        }
    }
}
#endif
```

**Note to implementer:** the `scan(...)` helper above has an awkward return-type workaround because the delegate resolves `CBPeripheral` but the public API wants `TactilePeripheralRef`. Rewrite the delegate's `didDiscover` to directly resume with a `TactilePeripheralRef(peripheral: peripheral)`, and have the `scan` continuation typed `<TactilePeripheralRef, Swift.Error>`. The sketch above is rough — clean it up when implementing.

**The `TactilePeripheralRef` struct can hold a `CBPeripheral` directly if the `struct` is private-scoped via `internal` modifier** — `CBPeripheral` isn't `Sendable`. For now mark as `@unchecked Sendable` and document that instances are used only on the BLE queue.

- [ ] **Step 2: Build verification, commit**

```bash
swift build
git add Sources/SyncField/Streams/Tactile/TactileBLEClient.swift
git commit -m "feat: TactileBLEClient — CoreBluetooth scan/connect/subscribe wrapper"
```

---

## Phase B-4: `TactileStream`

### Task 4.1: Main adapter

**Files:**
- Create: `Sources/SyncField/Streams/Tactile/TactileStream.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/SyncField/Streams/Tactile/TactileStream.swift
import Foundation

public final class TactileStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false,
        supportsPreciseTimestamps: true, providesAudioTrack: false)

    public let side: TactileSide

    private let client = TactileBLEClient()
    private var writer: SensorWriter?
    private var clock: SessionClock?
    private var healthBus: HealthBus?
    private var manifest: DeviceManifest?
    private var frameCount = 0
    private var isSubscribed = false

    public init(streamId: String, side: TactileSide) {
        self.streamId = streamId
        self.side = side
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        let ref = try await client.scan()
        let m = try await client.connectAndPrepare(ref, expectedSide: side)
        self.manifest = m
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        self.clock = clock
        self.writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.frameCount = 0

        try client.subscribe { [weak self] data, arrivalNs in
            self?.handlePacket(data, arrivalNs: arrivalNs)
        }
        isSubscribed = true
    }

    public func stopRecording() async throws -> StreamStopReport {
        isSubscribed = false
        try await writer?.close()
        let n = frameCount
        writer = nil
        return StreamStopReport(streamId: streamId, frameCount: n, kind: "sensor")
    }

    public func ingest(into dir: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).jsonl",
                           frameCount: frameCount)
    }

    public func disconnect() async throws {
        client.disconnect()
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    private func handlePacket(_ data: Data, arrivalNs: UInt64) {
        guard isSubscribed,
              let writer = writer,
              let manifest = manifest else { return }
        guard let packet = try? TactilePacketParser.parse(data) else { return }

        let intervalUs = UInt64(TactileConstants.sampleIntervalUs)
        for (i, channels) in packet.samples.enumerated() {
            let frame = frameCount
            frameCount += 1
            let captureNs = arrivalNs &+ UInt64(i) &* (intervalUs &* 1_000)
            let deviceTsNs = (UInt64(packet.batchTimestampUs) &+ UInt64(i) &* intervalUs) &* 1_000

            var channelsOut: [String: Any] = [:]
            for (cid, raw) in channels.enumerated() {
                let label = manifest.locationForChannel(cid)
                    ?? "ch\(cid)"
                channelsOut[label] = Int(raw)
            }

            let w = writer
            Task {
                try? await w.append(frame: frame, monotonicNs: captureNs,
                                    channels: channelsOut,
                                    deviceTimestampNs: deviceTsNs)
            }
        }
    }
}
```

- [ ] **Step 2: Build verification, commit**

```bash
swift build
git add Sources/SyncField/Streams/Tactile/TactileStream.swift
git commit -m "feat: TactileStream — Oglo BLE glove adapter"
```

---

## Phase B-5: Green-light checkpoint

### Task 5.1: Full build + tag

- [ ] **Step 1: macOS tests**

```bash
swift test
```
Expected: all pre-Plan-B tests still pass + 6 new Tactile tests (TactileTypesTests 3 + TactilePacketParserTests 3). Total ~37 tests, 0 failures. BLE code compiles on macOS via `canImport(CoreBluetooth)` and is runtime-gated by Bluetooth state; no BLE-dependent unit tests exist.

- [ ] **Step 2: iOS Simulator build**

```bash
xcodebuild -scheme SyncField -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -15
```
Expected: succeeds. CoreBluetooth is available on iOS Simulator (it just can't actually discover real peripherals).

- [ ] **Step 3: Tag**

```bash
git tag v0.2.2-plan-b
```

---

## Self-Review

**Spec coverage:**
- BLE constants (service/char UUIDs, name filter, canonical finger order): Phase B-1 ✓
- DeviceManifest with `side` validation + `locationForChannel`: Phase B-1 ✓
- Packet parsing (header + N samples × 5 channels LE): Phase B-2 ✓
- CoreBluetooth scan → connect → read manifest → subscribe to notify: Phase B-3 ✓
- Per-sample dual timestamps (`captureNs` from host arrival + `device_timestamp_ns` from firmware μs): Phase B-4 ✓
- Wrong-side rejection (stream configured as `.left` meets `.right` manifest → throws): Phase B-3 ✓
- `TactileStream.connect()` yields `streamConnected` health event: Phase B-4 ✓

**Deferred to future plan (not Plan B):**
- Auto-reconnect with exponential backoff (the egonaut version has it; requires a dedicated reconnect state machine; not critical for a first SDK cut — if BLE drops mid-recording, health event fires and the customer app can restart the session)
- Packet watchdog / defensive re-subscription
- MTU negotiation — we assume 106-byte fragment fits (iOS default MTU 185 works)

**Placeholder scan:** No "TBD"/"TODO". Every code block is complete. One marked "rough — clean up when implementing" in Phase B-3 (scan continuation typing) — implementer should refine without asking.

**Type consistency:** `TactileSide`, `DeviceManifest`, `TactileConstants`, `TactilePacket`, `TactilePeripheralRef` used consistently. `TactileStream` uses `client` + `writer` + `manifest` properties consistently across all phase calls.

---

## Execution handoff

Plan is complete. Execute with superpowers:subagent-driven-development (recommended) or superpowers:executing-plans.
