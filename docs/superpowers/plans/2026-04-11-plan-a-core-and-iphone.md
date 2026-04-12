# syncfield-swift v0.2 — Plan A: Core SDK + iPhone Adapters

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the v0.2 core SDK (5-phase lifecycle, Stream SPI, writers, orchestrator, health bus) and the `iPhoneCameraStream` + `iPhoneMotionStream` built-in adapters, plus the `SyncFieldUIKit` preview target, such that the `examples/egocentric-only/` integration example compiles and records a valid episode directory end-to-end.

**Architecture:** Swift Package with three targets — `SyncField` (core, actor-based, no external deps), `SyncFieldUIKit` (optional UIKit/SwiftUI preview helper), `SyncFieldTests` (unit tests on pure-logic components; on-device integration tests gated behind `#if canImport(AVFoundation) && os(iOS)`). 5-phase lifecycle (`IDLE → CONNECTED → RECORDING → STOPPING → INGESTING → CONNECTED`) driven by `SessionOrchestrator` actor. Stream protocol with five required methods. Atomic multi-stream start with compensating rollback.

**Tech Stack:** Swift 5.9, Swift Concurrency (actors, async/await, `AsyncStream`), AVFoundation, CoreMotion. Zero external Swift package dependencies.

**Spec:** [`docs/superpowers/specs/2026-04-11-swift-sdk-recording-design.md`](../specs/2026-04-11-swift-sdk-recording-design.md)

**Out-of-plan deliverables (follow-on plans):**
- Plan B — `TactileStream` (CoreBluetooth, Oglo gloves)
- Plan C — `Insta360CameraStream` (separate `SyncFieldInsta360` target)
- Plan D — `egonaut/mobile/ios` migration to v0.2

---

## Phase 0: Reset the package to a clean v0.2 skeleton

### Task 0.1: Delete the v0.1 sources and tests

**Files:**
- Delete: `Sources/SyncField/SyncSession.swift`
- Delete: `Sources/SyncField/Types.swift`
- Delete: `Sources/SyncField/Writer.swift`
- Delete: `Sources/SyncField/Clock.swift`
- Delete: `Tests/SyncFieldTests/SyncSessionTests.swift`

- [ ] **Step 1: Remove old source and test files**

```bash
rm Sources/SyncField/SyncSession.swift \
   Sources/SyncField/Types.swift \
   Sources/SyncField/Writer.swift \
   Sources/SyncField/Clock.swift \
   Tests/SyncFieldTests/SyncSessionTests.swift
```

- [ ] **Step 2: Verify package still resolves (empty target is legal)**

Run: `swift package resolve`
Expected: no error.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove v0.1 sources in preparation for v0.2 rewrite"
```

### Task 0.2: Update `Package.swift` for multi-target layout

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Replace Package.swift contents**

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SyncField",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "SyncField",      targets: ["SyncField"]),
        .library(name: "SyncFieldUIKit", targets: ["SyncFieldUIKit"]),
    ],
    targets: [
        .target(name: "SyncField"),
        .target(name: "SyncFieldUIKit", dependencies: ["SyncField"]),
        .testTarget(name: "SyncFieldTests", dependencies: ["SyncField"]),
    ]
)
```

- [ ] **Step 2: Create the empty `SyncFieldUIKit` directory**

```bash
mkdir -p Sources/SyncFieldUIKit
touch Sources/SyncFieldUIKit/.gitkeep
```

- [ ] **Step 3: Verify the package builds**

Run: `swift build`
Expected: build succeeds (empty targets).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/SyncFieldUIKit/.gitkeep
git commit -m "chore: add SyncFieldUIKit target scaffold"
```

---

## Phase 1: Core value types

### Task 1.1: `SessionState` enum

**Files:**
- Create: `Sources/SyncField/SessionState.swift`
- Create: `Tests/SyncFieldTests/SessionStateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SyncFieldTests/SessionStateTests.swift
import XCTest
@testable import SyncField

final class SessionStateTests: XCTestCase {
    func test_all_cases_are_distinct_and_codable() throws {
        let all: [SessionState] = [.idle, .connected, .recording, .stopping, .ingesting]
        let encoded = try JSONEncoder().encode(all)
        let decoded = try JSONDecoder().decode([SessionState].self, from: encoded)
        XCTAssertEqual(decoded, all)
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `swift test --filter SessionStateTests`
Expected: FAIL — `SessionState` undefined.

- [ ] **Step 3: Implement `SessionState`**

```swift
// Sources/SyncField/SessionState.swift
import Foundation

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle
    case connected
    case recording
    case stopping
    case ingesting
}
```

- [ ] **Step 4: Run the test and confirm pass**

Run: `swift test --filter SessionStateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncField/SessionState.swift Tests/SyncFieldTests/SessionStateTests.swift
git commit -m "feat: add SessionState enum"
```

### Task 1.2: `SyncPoint`

**Files:**
- Create: `Sources/SyncField/SyncPoint.swift`
- Create: `Tests/SyncFieldTests/SyncPointTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SyncFieldTests/SyncPointTests.swift
import XCTest
@testable import SyncField

final class SyncPointTests: XCTestCase {
    func test_round_trip_json_preserves_all_fields() throws {
        let sp = SyncPoint(
            sdkVersion: "0.2.0",
            monotonicNs: 12_345_678,
            wallClockNs: 1_700_000_000_000_000_000,
            hostId: "iphone_ego",
            isoDatetime: "2026-04-11T15:29:30Z"
        )
        let data = try JSONEncoder().encode(sp)
        let decoded = try JSONDecoder().decode(SyncPoint.self, from: data)
        XCTAssertEqual(decoded, sp)
    }

    func test_json_keys_match_server_contract() throws {
        let sp = SyncPoint(sdkVersion: "0.2.0", monotonicNs: 1, wallClockNs: 2,
                           hostId: "h", isoDatetime: "d")
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sp)) as! [String: Any]
        XCTAssertEqual(Set(dict.keys), ["sdk_version", "monotonic_ns",
                                        "wall_clock_ns", "host_id", "iso_datetime"])
    }
}
```

- [ ] **Step 2: Run and confirm FAIL**

Run: `swift test --filter SyncPointTests`

- [ ] **Step 3: Implement `SyncPoint`**

```swift
// Sources/SyncField/SyncPoint.swift
import Foundation

public struct SyncPoint: Codable, Equatable, Sendable {
    public let sdkVersion: String
    public let monotonicNs: UInt64
    public let wallClockNs: UInt64
    public let hostId: String
    public let isoDatetime: String

    public init(sdkVersion: String, monotonicNs: UInt64, wallClockNs: UInt64,
                hostId: String, isoDatetime: String) {
        self.sdkVersion  = sdkVersion
        self.monotonicNs = monotonicNs
        self.wallClockNs = wallClockNs
        self.hostId      = hostId
        self.isoDatetime = isoDatetime
    }

    enum CodingKeys: String, CodingKey {
        case sdkVersion  = "sdk_version"
        case monotonicNs = "monotonic_ns"
        case wallClockNs = "wall_clock_ns"
        case hostId      = "host_id"
        case isoDatetime = "iso_datetime"
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

Run: `swift test --filter SyncPointTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncField/SyncPoint.swift Tests/SyncFieldTests/SyncPointTests.swift
git commit -m "feat: add SyncPoint struct matching server JSON contract"
```

### Task 1.3: `HealthEvent` enum

**Files:**
- Create: `Sources/SyncField/HealthEvent.swift`

- [ ] **Step 1: Implement `HealthEvent`**

```swift
// Sources/SyncField/HealthEvent.swift
import Foundation

public enum HealthEvent: Sendable {
    case streamConnected(streamId: String)
    case streamDisconnected(streamId: String, reason: String)
    case samplesDropped(streamId: String, count: Int)
    case ingestProgress(streamId: String, fraction: Double)
    case ingestFailed(streamId: String, error: Error)
}
```

Note: `HealthEvent` is not `Equatable` because `Error` isn't. Tested indirectly via `HealthBus` tests in Task 4.1.

- [ ] **Step 2: Verify it compiles**

Run: `swift build`

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncField/HealthEvent.swift
git commit -m "feat: add HealthEvent enum"
```

### Task 1.4: `StreamCapabilities`

**Files:**
- Create: `Sources/SyncField/StreamCapabilities.swift`
- Create: `Tests/SyncFieldTests/StreamCapabilitiesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SyncFieldTests/StreamCapabilitiesTests.swift
import XCTest
@testable import SyncField

final class StreamCapabilitiesTests: XCTestCase {
    func test_default_is_native_live_stream() {
        let c = StreamCapabilities()
        XCTAssertFalse(c.requiresIngest)
        XCTAssertTrue(c.producesFile)
        XCTAssertTrue(c.supportsPreciseTimestamps)
    }

    func test_json_uses_snake_case() throws {
        let c = StreamCapabilities(requiresIngest: true, producesFile: true,
                                   supportsPreciseTimestamps: false)
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(c)) as! [String: Any]
        XCTAssertEqual(Set(dict.keys),
                       ["requires_ingest", "produces_file",
                        "supports_precise_timestamps"])
    }
}
```

- [ ] **Step 2: Run FAIL, implement, run PASS**

```swift
// Sources/SyncField/StreamCapabilities.swift
import Foundation

public struct StreamCapabilities: Codable, Equatable, Sendable {
    public var requiresIngest: Bool
    public var producesFile: Bool
    public var supportsPreciseTimestamps: Bool

    public init(requiresIngest: Bool = false,
                producesFile: Bool = true,
                supportsPreciseTimestamps: Bool = true) {
        self.requiresIngest = requiresIngest
        self.producesFile   = producesFile
        self.supportsPreciseTimestamps = supportsPreciseTimestamps
    }

    enum CodingKeys: String, CodingKey {
        case requiresIngest = "requires_ingest"
        case producesFile   = "produces_file"
        case supportsPreciseTimestamps = "supports_precise_timestamps"
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncField/StreamCapabilities.swift Tests/SyncFieldTests/StreamCapabilitiesTests.swift
git commit -m "feat: add StreamCapabilities"
```

### Task 1.5: Errors — `SessionError` and `StreamError`

**Files:**
- Create: `Sources/SyncField/Errors.swift`

- [ ] **Step 1: Implement errors**

```swift
// Sources/SyncField/Errors.swift
import Foundation

public enum SessionError: Error, CustomStringConvertible {
    case invalidTransition(from: SessionState, to: SessionState)
    case duplicateStreamId(String)
    case noStreamsRegistered
    case startFailed(cause: Error, rolledBack: [String])
    case notRunning

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "SessionError: cannot transition from \(from) to \(to)"
        case .duplicateStreamId(let id):
            return "SessionError: duplicate streamId '\(id)'"
        case .noStreamsRegistered:
            return "SessionError: no streams registered"
        case .startFailed(let cause, let rolledBack):
            return "SessionError: startRecording failed (\(cause)); rolled back \(rolledBack)"
        case .notRunning:
            return "SessionError: operation requires the session to be running"
        }
    }
}

public struct StreamError: Error, CustomStringConvertible {
    public let streamId: String
    public let underlying: Error

    public init(streamId: String, underlying: Error) {
        self.streamId = streamId
        self.underlying = underlying
    }

    public var description: String {
        "StreamError[\(streamId)]: \(underlying)"
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SyncField/Errors.swift
git commit -m "feat: add SessionError and StreamError types"
```

---

## Phase 2: `SessionClock`

### Task 2.1: Monotonic + wall clock + mach-time conversion

**Files:**
- Create: `Sources/SyncField/SessionClock.swift`
- Create: `Tests/SyncFieldTests/SessionClockTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SyncFieldTests/SessionClockTests.swift
import XCTest
@testable import SyncField

final class SessionClockTests: XCTestCase {
    func test_now_ns_is_monotonic_nondecreasing() {
        let clock = SessionClock()
        let a = clock.nowMonotonicNs()
        let b = clock.nowMonotonicNs()
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func test_anchor_captures_both_monotonic_and_wall() {
        let clock = SessionClock()
        let anchor = clock.anchor(hostId: "h")
        XCTAssertGreaterThan(anchor.monotonicNs, 0)
        XCTAssertGreaterThan(anchor.wallClockNs, 1_600_000_000_000_000_000)  // after 2020
        XCTAssertEqual(anchor.hostId, "h")
        XCTAssertFalse(anchor.isoDatetime.isEmpty)
    }

    func test_mach_ticks_to_ns_conversion_is_identity_on_arm64() {
        // On Apple Silicon, 1 mach tick == 1 ns (numer == denom == 1).
        // This test asserts the conversion path works; exact ratio is platform-specific.
        let clock = SessionClock()
        let ticks: UInt64 = 1_000_000_000
        let ns = clock.machTicksToMonotonicNs(ticks)
        XCTAssertGreaterThan(ns, 0)
    }
}
```

- [ ] **Step 2: Run FAIL**

Run: `swift test --filter SessionClockTests`

- [ ] **Step 3: Implement `SessionClock`**

```swift
// Sources/SyncField/SessionClock.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Provides the monotonic clock used to stamp every frame in a session,
/// plus a wall-clock anchor captured once at session start.
public final class SessionClock: @unchecked Sendable {
    private let timebase: mach_timebase_info_data_t

    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        self.timebase = tb
    }

    /// Current monotonic clock in nanoseconds. Never goes backwards.
    public func nowMonotonicNs() -> UInt64 {
        machTicksToMonotonicNs(mach_absolute_time())
    }

    /// Convert a CoreMotion / AVFoundation mach-tick timestamp to session ns.
    public func machTicksToMonotonicNs(_ ticks: UInt64) -> UInt64 {
        // ns = ticks * numer / denom
        let num = UInt64(timebase.numer)
        let den = UInt64(timebase.denom)
        return ticks &* num / den
    }

    /// Capture a `SyncPoint` anchoring monotonic to wall clock.
    public func anchor(hostId: String, sdkVersion: String = SyncFieldVersion.current) -> SyncPoint {
        let mono = nowMonotonicNs()
        let wall = UInt64(Date().timeIntervalSince1970 * 1_000_000_000.0)
        let iso  = ISO8601DateFormatter().string(from: Date())
        return SyncPoint(sdkVersion: sdkVersion,
                         monotonicNs: mono, wallClockNs: wall,
                         hostId: hostId, isoDatetime: iso)
    }
}

public enum SyncFieldVersion {
    public static let current = "0.2.0"
}
```

- [ ] **Step 4: Run PASS**

Run: `swift test --filter SessionClockTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncField/SessionClock.swift Tests/SyncFieldTests/SessionClockTests.swift
git commit -m "feat: add SessionClock with mach-to-ns conversion and SyncPoint anchor"
```

---

## Phase 3: Writers

### Task 3.1: `StreamWriter` (timestamps JSONL)

**Files:**
- Create: `Sources/SyncField/Writers/StreamWriter.swift`
- Create: `Tests/SyncFieldTests/StreamWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SyncFieldTests/StreamWriterTests.swift
import XCTest
@testable import SyncField

final class StreamWriterTests: XCTestCase {
    func test_writes_one_json_line_per_frame_and_flushes_on_close() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("cam.timestamps.jsonl")
        let writer = try await StreamWriter(url: url)
        try await writer.append(frame: 0, monotonicNs: 1_000, uncertaintyNs: 5_000_000)
        try await writer.append(frame: 1, monotonicNs: 2_000, uncertaintyNs: 5_000_000)
        try await writer.close()

        let lines = try String(contentsOf: url).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)

        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(first["frame"] as? Int, 0)
        XCTAssertEqual(first["timestamp_ns"] as? UInt64, 1_000)
        XCTAssertEqual(first["uncertainty_ns"] as? UInt64, 5_000_000)
    }
}
```

- [ ] **Step 2: Run FAIL**

- [ ] **Step 3: Implement `StreamWriter`**

```swift
// Sources/SyncField/Writers/StreamWriter.swift
import Foundation

/// Writes one JSON line per video frame timestamp.
/// Each call to `append` is atomic w.r.t. the writer actor.
public actor StreamWriter {
    private let handle: FileHandle
    private var frameCount: Int = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public var count: Int { frameCount }

    public func append(frame: Int, monotonicNs: UInt64, uncertaintyNs: UInt64) throws {
        let obj: [String: Any] = [
            "frame": frame,
            "timestamp_ns": monotonicNs,
            "uncertainty_ns": uncertaintyNs,
        ]
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)  // '\n'
        try handle.write(contentsOf: data)
        frameCount += 1
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
```

- [ ] **Step 4: Run PASS, commit**

```bash
git add Sources/SyncField/Writers/StreamWriter.swift Tests/SyncFieldTests/StreamWriterTests.swift
git commit -m "feat: add actor-isolated StreamWriter for frame timestamps JSONL"
```

### Task 3.2: `SensorWriter`

**Files:**
- Create: `Sources/SyncField/Writers/SensorWriter.swift`
- Create: `Tests/SyncFieldTests/SensorWriterTests.swift`

- [ ] **Step 1: Write test**

```swift
// Tests/SyncFieldTests/SensorWriterTests.swift
import XCTest
@testable import SyncField

final class SensorWriterTests: XCTestCase {
    func test_writes_channels_as_nested_json_object() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("imu.jsonl")
        let w = try await SensorWriter(url: url)
        try await w.append(frame: 0, monotonicNs: 123,
                           channels: ["accel_x": 0.1, "accel_y": -9.8])
        try await w.close()

        let line = try String(contentsOf: url).split(separator: "\n").first!
        let obj = try JSONSerialization.jsonObject(with: Data(String(line).utf8)) as! [String: Any]
        XCTAssertEqual(obj["frame"] as? Int, 0)
        let channels = obj["channels"] as! [String: Any]
        XCTAssertEqual(channels["accel_x"] as? Double, 0.1)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/SyncField/Writers/SensorWriter.swift
import Foundation

public actor SensorWriter {
    private let handle: FileHandle
    private var frameCount: Int = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public var count: Int { frameCount }

    public func append(frame: Int, monotonicNs: UInt64,
                       channels: [String: Any],
                       deviceTimestampNs: UInt64? = nil) throws {
        var obj: [String: Any] = [
            "frame": frame,
            "timestamp_ns": monotonicNs,
            "channels": channels,
        ]
        if let dts = deviceTimestampNs { obj["device_timestamp_ns"] = dts }

        var data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        frameCount += 1
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
```

- [ ] **Step 3: Run PASS, commit**

```bash
git add Sources/SyncField/Writers/SensorWriter.swift Tests/SyncFieldTests/SensorWriterTests.swift
git commit -m "feat: add actor-isolated SensorWriter for sensor sample JSONL"
```

### Task 3.3: `SessionLogWriter` (crash-safe line flush)

**Files:**
- Create: `Sources/SyncField/Writers/SessionLogWriter.swift`
- Create: `Tests/SyncFieldTests/SessionLogWriterTests.swift`

- [ ] **Step 1: Write test**

```swift
// Tests/SyncFieldTests/SessionLogWriterTests.swift
import XCTest
@testable import SyncField

final class SessionLogWriterTests: XCTestCase {
    func test_every_entry_is_immediately_visible_on_disk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("session.log")
        let log = try await SessionLogWriter(url: url)
        try await log.append(kind: "state", detail: "idle->connected")

        let content = try String(contentsOf: url)
        XCTAssertTrue(content.contains("state"))
        XCTAssertTrue(content.contains("idle->connected"))

        try await log.append(kind: "health", detail: "tactile_left dropped 2")
        try await log.close()

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/SyncField/Writers/SessionLogWriter.swift
import Foundation

/// Append-only session log. Each call fsyncs before returning so entries
/// survive a crash. One JSON object per line.
public actor SessionLogWriter {
    private let handle: FileHandle
    private let isoFormatter: ISO8601DateFormatter

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func append(kind: String, detail: String) throws {
        let entry: [String: Any] = [
            "ts":     isoFormatter.string(from: Date()),
            "kind":   kind,
            "detail": detail,
        ]
        var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()  // fsync on every entry
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncField/Writers/SessionLogWriter.swift Tests/SyncFieldTests/SessionLogWriterTests.swift
git commit -m "feat: add crash-safe SessionLogWriter"
```

### Task 3.4: `ManifestWriter` (final summary)

**Files:**
- Create: `Sources/SyncField/Writers/ManifestWriter.swift`
- Create: `Tests/SyncFieldTests/ManifestWriterTests.swift`

- [ ] **Step 1: Write test**

```swift
// Tests/SyncFieldTests/ManifestWriterTests.swift
import XCTest
@testable import SyncField

final class ManifestWriterTests: XCTestCase {
    func test_writes_expected_top_level_keys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = Manifest(
            sdkVersion: "0.2.0", hostId: "h", role: "single",
            streams: [
                .init(streamId: "cam_ego", filePath: "cam_ego.mp4",
                      frameCount: 120, kind: "video",
                      capabilities: StreamCapabilities()),
            ])
        let url = dir.appendingPathComponent("manifest.json")
        try ManifestWriter.write(manifest, to: url)

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(dict["sdk_version"] as? String, "0.2.0")
        XCTAssertEqual(dict["host_id"] as? String, "h")
        XCTAssertEqual(dict["role"] as? String, "single")
        XCTAssertNotNil(dict["streams"])
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/SyncField/Writers/ManifestWriter.swift
import Foundation

public struct Manifest: Codable, Sendable {
    public struct StreamEntry: Codable, Sendable {
        public let streamId: String
        public let filePath: String
        public let frameCount: Int
        public let kind: String           // "video" | "sensor"
        public let capabilities: StreamCapabilities

        public init(streamId: String, filePath: String, frameCount: Int,
                    kind: String, capabilities: StreamCapabilities) {
            self.streamId = streamId; self.filePath = filePath
            self.frameCount = frameCount; self.kind = kind
            self.capabilities = capabilities
        }

        enum CodingKeys: String, CodingKey {
            case streamId     = "stream_id"
            case filePath     = "file_path"
            case frameCount   = "frame_count"
            case kind
            case capabilities
        }
    }

    public let sdkVersion: String
    public let hostId: String
    public let role: String                // v0.2: always "single"
    public let streams: [StreamEntry]

    public init(sdkVersion: String, hostId: String, role: String, streams: [StreamEntry]) {
        self.sdkVersion = sdkVersion; self.hostId = hostId
        self.role = role; self.streams = streams
    }

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case hostId     = "host_id"
        case role, streams
    }
}

public enum ManifestWriter {
    public static func write(_ manifest: Manifest, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: url, options: [.atomic])
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncField/Writers/ManifestWriter.swift Tests/SyncFieldTests/ManifestWriterTests.swift
git commit -m "feat: add Manifest type and ManifestWriter"
```

### Task 3.5: `WriterFactory`

**Files:**
- Create: `Sources/SyncField/Writers/WriterFactory.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/SyncField/Writers/WriterFactory.swift
import Foundation

/// Injected into `Stream.startRecording` so the stream creates writers
/// rooted at the episode directory, without knowing the directory path.
public struct WriterFactory: Sendable {
    public let episodeDirectory: URL

    public init(episodeDirectory: URL) { self.episodeDirectory = episodeDirectory }

    public func makeStreamWriter(streamId: String) throws -> StreamWriter {
        try StreamWriter(url: episodeDirectory
            .appendingPathComponent("\(streamId).timestamps.jsonl"))
    }

    public func makeSensorWriter(streamId: String) throws -> SensorWriter {
        try SensorWriter(url: episodeDirectory
            .appendingPathComponent("\(streamId).jsonl"))
    }

    public func videoURL(streamId: String, extension ext: String = "mp4") -> URL {
        episodeDirectory.appendingPathComponent("\(streamId).\(ext)")
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SyncField/Writers/WriterFactory.swift
git commit -m "feat: add WriterFactory for stream-local writer creation"
```

---

## Phase 4: `HealthBus`

### Task 4.1: AsyncStream fan-out

**Files:**
- Create: `Sources/SyncField/HealthBus.swift`
- Create: `Tests/SyncFieldTests/HealthBusTests.swift`

- [ ] **Step 1: Write test**

```swift
// Tests/SyncFieldTests/HealthBusTests.swift
import XCTest
@testable import SyncField

final class HealthBusTests: XCTestCase {
    func test_multiple_subscribers_receive_same_events() async {
        let bus = HealthBus()
        let sub1 = bus.subscribe()
        let sub2 = bus.subscribe()

        Task {
            await bus.publish(.streamConnected(streamId: "a"))
            await bus.publish(.streamConnected(streamId: "b"))
            bus.finish()
        }

        var got1: [String] = []
        for await ev in sub1 {
            if case .streamConnected(let id) = ev { got1.append(id) }
        }
        var got2: [String] = []
        for await ev in sub2 {
            if case .streamConnected(let id) = ev { got2.append(id) }
        }
        XCTAssertEqual(got1, ["a", "b"])
        XCTAssertEqual(got2, ["a", "b"])
    }
}
```

- [ ] **Step 2: Run FAIL**

- [ ] **Step 3: Implement**

```swift
// Sources/SyncField/HealthBus.swift
import Foundation

/// In-process event bus for stream lifecycle signals.
/// Subscribers are not back-pressured; `bufferingPolicy: .bufferingNewest(64)`
/// drops oldest events when a slow subscriber falls behind.
public final class HealthBus: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<HealthEvent>.Continuation] = [:]
    private let lock = NSLock()

    public init() {}

    public func subscribe() -> AsyncStream<HealthEvent> {
        AsyncStream(HealthEvent.self, bufferingPolicy: .bufferingNewest(64)) { cont in
            let id = UUID()
            lock.lock(); continuations[id] = cont; lock.unlock()

            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations.removeValue(forKey: id); self.lock.unlock()
            }
        }
    }

    public func publish(_ event: HealthEvent) async {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for cont in targets { cont.yield(event) }
    }

    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for cont in targets { cont.finish() }
    }
}
```

- [ ] **Step 4: Run PASS, commit**

```bash
git add Sources/SyncField/HealthBus.swift Tests/SyncFieldTests/HealthBusTests.swift
git commit -m "feat: add HealthBus for stream health event fan-out"
```

---

## Phase 5: `Stream` protocol and supporting types

### Task 5.1: `Stream` protocol + context + reports

**Files:**
- Create: `Sources/SyncField/Stream.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/SyncField/Stream.swift
import Foundation

public struct StreamConnectContext: Sendable {
    public let sessionId: String
    public let hostId: String
    public let healthBus: HealthBus

    public init(sessionId: String, hostId: String, healthBus: HealthBus) {
        self.sessionId = sessionId; self.hostId = hostId; self.healthBus = healthBus
    }
}

public struct StreamStopReport: Sendable {
    public let streamId: String
    public let frameCount: Int
    public let kind: String

    public init(streamId: String, frameCount: Int, kind: String) {
        self.streamId = streamId; self.frameCount = frameCount; self.kind = kind
    }
}

public struct StreamIngestReport: Sendable {
    public let streamId: String
    public let filePath: String?        // relative to episode dir; nil if no file produced
    public let frameCount: Int?         // e.g. from timestamps.jsonl after ingest

    public init(streamId: String, filePath: String?, frameCount: Int?) {
        self.streamId = streamId; self.filePath = filePath; self.frameCount = frameCount
    }
}

/// Custom adapter contract. Implemented by `iPhoneCameraStream`,
/// `iPhoneMotionStream`, `TactileStream`, `Insta360CameraStream`, etc.
public protocol Stream: Sendable {
    var streamId: String { get }
    var capabilities: StreamCapabilities { get }

    func prepare() async throws
    func connect(context: StreamConnectContext) async throws
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws
    func stopRecording() async throws -> StreamStopReport
    func ingest(into episodeDirectory: URL,
                progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport
    func disconnect() async throws
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SyncField/Stream.swift
git commit -m "feat: add Stream protocol and supporting context/report types"
```

---

## Phase 6: `SessionOrchestrator`

### Task 6.1: State machine + lifecycle methods (no streams yet)

**Files:**
- Create: `Sources/SyncField/SessionOrchestrator.swift`
- Create: `Tests/SyncFieldTests/SessionOrchestratorStateMachineTests.swift`
- Create: `Tests/SyncFieldTests/MockStream.swift`

- [ ] **Step 1: Write the `MockStream` helper**

```swift
// Tests/SyncFieldTests/MockStream.swift
import Foundation
@testable import SyncField

actor MockStream: Stream {
    let streamId: String
    let capabilities: StreamCapabilities

    enum FailAt { case none, prepare, connect, start, stop, ingest, disconnect }
    var failAt: FailAt = .none

    var prepared = false
    var connected = false
    var recording = false
    var ingested  = false

    init(streamId: String, requiresIngest: Bool = false) {
        self.streamId = streamId
        self.capabilities = StreamCapabilities(requiresIngest: requiresIngest)
    }

    nonisolated var capabilities_nonisolated: StreamCapabilities { capabilities }

    func prepare() async throws { if failAt == .prepare { throw TestError.boom }; prepared = true }
    func connect(context: StreamConnectContext) async throws {
        if failAt == .connect { throw TestError.boom }; connected = true
    }
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {
        if failAt == .start { throw TestError.boom }; recording = true
    }
    func stopRecording() async throws -> StreamStopReport {
        if failAt == .stop { throw TestError.boom }
        recording = false
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "sensor")
    }
    func ingest(into dir: URL, progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        if failAt == .ingest { throw TestError.boom }
        ingested = true
        return StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
    }
    func disconnect() async throws {
        if failAt == .disconnect { throw TestError.boom }; connected = false
    }
}

enum TestError: Error { case boom }
```

Note: `Stream` requires `capabilities` be nonisolated-accessible. To keep `MockStream` an actor, expose it through the protocol via a nonisolated stored property. Update `Stream` accordingly:

```swift
// Amend Sources/SyncField/Stream.swift — make streamId and capabilities
// available synchronously. Actors satisfy this with nonisolated let.
public protocol Stream: Sendable {
    nonisolated var streamId: String { get }
    nonisolated var capabilities: StreamCapabilities { get }
    // ... rest unchanged ...
}
```

And in `MockStream` make both `nonisolated let`.

- [ ] **Step 2: Write the state machine tests**

```swift
// Tests/SyncFieldTests/SessionOrchestratorStateMachineTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorStateMachineTests: XCTestCase {
    func makeSession() -> (SessionOrchestrator, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionOrchestrator(hostId: "h", outputDirectory: dir), dir)
    }

    func test_initial_state_is_idle() async {
        let (s, _) = makeSession()
        let state = await s.state
        XCTAssertEqual(state, .idle)
    }

    func test_happy_path_transitions() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))

        try await s.connect()
        var state = await s.state; XCTAssertEqual(state, .connected)

        _ = try await s.startRecording()
        state = await s.state; XCTAssertEqual(state, .recording)

        _ = try await s.stopRecording()
        state = await s.state; XCTAssertEqual(state, .stopping)

        _ = try await s.ingest { _ in }
        state = await s.state; XCTAssertEqual(state, .connected)

        try await s.disconnect()
        state = await s.state; XCTAssertEqual(state, .idle)
    }

    func test_start_without_connect_throws_invalid_transition() async {
        let (s, _) = makeSession()
        try? await s.add(MockStream(streamId: "a"))
        do {
            _ = try await s.startRecording()
            XCTFail("expected throw")
        } catch let SessionError.invalidTransition(from, _) {
            XCTAssertEqual(from, .idle)
        } catch { XCTFail("unexpected \(error)") }
    }

    func test_add_duplicate_stream_id_throws() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        do {
            try await s.add(MockStream(streamId: "a"))
            XCTFail("expected throw")
        } catch SessionError.duplicateStreamId { /* ok */ }
        catch { XCTFail("unexpected \(error)") }
    }
}
```

- [ ] **Step 3: Implement `SessionOrchestrator`**

```swift
// Sources/SyncField/SessionOrchestrator.swift
import Foundation

public actor SessionOrchestrator {
    // MARK: Public API

    public init(hostId: String, outputDirectory: URL) {
        self.hostId = hostId
        self.baseDir = outputDirectory
    }

    public private(set) var state: SessionState = .idle
    public private(set) var episodeDirectory: URL = URL(fileURLWithPath: "/")

    public var healthEvents: AsyncStream<HealthEvent> { bus.subscribe() }

    public func add(_ stream: any Stream) throws {
        guard state == .idle else {
            throw SessionError.invalidTransition(from: state, to: state)
        }
        if streams.contains(where: { $0.streamId == stream.streamId }) {
            throw SessionError.duplicateStreamId(stream.streamId)
        }
        streams.append(stream)
    }

    public func connect() async throws {
        try require(state: .idle, next: .connected)
        guard !streams.isEmpty else { throw SessionError.noStreamsRegistered }

        sessionId = UUID().uuidString.prefix(12).lowercased()
        for s in streams {
            do {
                try await s.prepare()
                try await s.connect(context: .init(
                    sessionId: String(sessionId),
                    hostId: hostId,
                    healthBus: bus))
            } catch {
                // undo any already-connected streams
                for already in streams where already.streamId != s.streamId {
                    try? await already.disconnect()
                }
                state = .idle
                throw StreamError(streamId: s.streamId, underlying: error)
            }
        }
        state = .connected
    }

    @discardableResult
    public func startRecording(countdown: Duration = .zero) async throws -> SyncPoint {
        try require(state: .connected, next: .recording)

        episodeDirectory = try makeEpisodeDirectory()
        let clock = SessionClock()
        let factory = WriterFactory(episodeDirectory: episodeDirectory)

        let anchor = clock.anchor(hostId: hostId)
        try writeSyncPoint(anchor)
        logWriter = try SessionLogWriter(url: episodeDirectory.appendingPathComponent("session.log"))
        try await logWriter!.append(kind: "state", detail: "connected->recording")

        self.activeClock = clock

        if countdown > .zero { try await Task.sleep(for: countdown) }

        // Atomic start: try all concurrently; roll back any that succeeded if any fails.
        var started: [String] = []
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                for s in streams {
                    group.addTask { [s] in
                        try await s.startRecording(clock: clock, writerFactory: factory)
                        return s.streamId
                    }
                }
                for try await id in group { started.append(id) }
            }
        } catch {
            // Roll back: stop the ones that started, delete their files.
            for s in streams where started.contains(s.streamId) {
                _ = try? await s.stopRecording()
            }
            try? FileManager.default.removeItem(at: episodeDirectory)
            state = .connected
            throw SessionError.startFailed(cause: error, rolledBack: started)
        }

        state = .recording
        return anchor
    }

    public func stopRecording() async throws -> StopReport {
        try require(state: .recording, next: .stopping)
        var reports: [StreamStopReport] = []
        for s in streams {
            do { reports.append(try await s.stopRecording()) }
            catch { throw StreamError(streamId: s.streamId, underlying: error) }
        }
        try await logWriter?.append(kind: "state", detail: "recording->stopping")
        state = .stopping
        return StopReport(streamReports: reports)
    }

    public func ingest(progress: @Sendable (IngestProgress) -> Void) async throws -> IngestReport {
        try require(state: .stopping, next: .ingesting)

        var results: [String: Result<StreamIngestReport, Error>] = [:]
        for s in streams {
            let id = s.streamId
            do {
                let report = try await s.ingest(into: episodeDirectory) { fraction in
                    progress(IngestProgress(streamId: id, fraction: fraction))
                }
                results[id] = .success(report)
            } catch {
                await bus.publish(.ingestFailed(streamId: id, error: error))
                results[id] = .failure(error)
            }
        }

        try writeManifest(from: results)
        try await logWriter?.append(kind: "state", detail: "ingesting->connected")
        try await logWriter?.close()
        logWriter = nil

        state = .connected
        return IngestReport(streamResults: results)
    }

    public func disconnect() async throws {
        try require(state: .connected, next: .idle)
        for s in streams {
            try? await s.disconnect()
        }
        bus.finish()
        state = .idle
    }

    // MARK: Private

    private let hostId: String
    private let baseDir: URL
    private var streams: [any Stream] = []
    private var sessionId: String = ""
    private var activeClock: SessionClock?
    private var logWriter: SessionLogWriter?
    private let bus = HealthBus()

    private func require(state expected: SessionState, next: SessionState) throws {
        let allowed: [(from: SessionState, to: SessionState)] = [
            (.idle, .connected),
            (.connected, .recording),
            (.recording, .stopping),
            (.stopping, .ingesting),
            (.ingesting, .connected),
            (.connected, .idle),
        ]
        guard state == expected,
              allowed.contains(where: { $0.from == expected && $0.to == next }) else {
            throw SessionError.invalidTransition(from: state, to: next)
        }
    }

    private func makeEpisodeDirectory() throws -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.timeZone = TimeZone(identifier: "UTC")
        let stamp = df.string(from: Date())
        let short = UUID().uuidString.prefix(6).lowercased()
        let dir = baseDir.appendingPathComponent("ep_\(stamp)_\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSyncPoint(_ sp: SyncPoint) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(sp).write(to: episodeDirectory
            .appendingPathComponent("sync_point.json"), options: [.atomic])
    }

    private func writeManifest(
        from results: [String: Result<StreamIngestReport, Error>]) throws {
        let entries: [Manifest.StreamEntry] = streams.map { s in
            let report = (try? results[s.streamId]?.get()) ?? nil
            return Manifest.StreamEntry(
                streamId: s.streamId,
                filePath: report?.filePath ?? "\(s.streamId).jsonl",
                frameCount: report?.frameCount ?? 0,
                kind: s.capabilities.producesFile ? "video" : "sensor",
                capabilities: s.capabilities)
        }
        let manifest = Manifest(sdkVersion: SyncFieldVersion.current,
                                hostId: hostId, role: "single", streams: entries)
        try ManifestWriter.write(manifest,
            to: episodeDirectory.appendingPathComponent("manifest.json"))
    }
}

public struct StopReport: Sendable {
    public let streamReports: [StreamStopReport]
}

public struct IngestProgress: Sendable {
    public let streamId: String
    public let fraction: Double
}

public struct IngestReport: Sendable {
    public let streamResults: [String: Result<StreamIngestReport, Error>]
}
```

- [ ] **Step 4: Run the state-machine tests, confirm PASS**

Run: `swift test --filter SessionOrchestratorStateMachineTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncField/SessionOrchestrator.swift \
        Sources/SyncField/Stream.swift \
        Tests/SyncFieldTests/MockStream.swift \
        Tests/SyncFieldTests/SessionOrchestratorStateMachineTests.swift
git commit -m "feat: SessionOrchestrator state machine with 5-phase lifecycle"
```

### Task 6.2: Atomic start — rollback on failure

**Files:**
- Create: `Tests/SyncFieldTests/SessionOrchestratorAtomicStartTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SyncFieldTests/SessionOrchestratorAtomicStartTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorAtomicStartTests: XCTestCase {
    func test_failure_in_one_stream_rolls_back_others_and_deletes_files() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let good = MockStream(streamId: "good")
        let bad  = MockStream(streamId: "bad")
        await bad.setFailAt(.start)
        try await s.add(good)
        try await s.add(bad)

        try await s.connect()
        do {
            _ = try await s.startRecording()
            XCTFail("expected startFailed")
        } catch SessionError.startFailed {
            // expected
        }

        // The episode directory that was created must be gone.
        let children = try FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(children.count, 0, "rollback must remove the episode directory")

        // good stream must have been stopped.
        let isRecording = await good.recording
        XCTAssertFalse(isRecording)

        let state = await s.state
        XCTAssertEqual(state, .connected)
    }
}
```

Add `func setFailAt(_ f: FailAt)` to `MockStream`:

```swift
extension MockStream {
    func setFailAt(_ f: FailAt) { self.failAt = f }
}
```

- [ ] **Step 2: Run — should already PASS** given the implementation in 6.1, but run to verify.

Run: `swift test --filter SessionOrchestratorAtomicStartTests`

- [ ] **Step 3: Commit**

```bash
git add Tests/SyncFieldTests/SessionOrchestratorAtomicStartTests.swift \
        Tests/SyncFieldTests/MockStream.swift
git commit -m "test: cover atomic start rollback path"
```

### Task 6.3: Partial ingest failure — other streams still succeed

**Files:**
- Create: `Tests/SyncFieldTests/SessionOrchestratorIngestTests.swift`

- [ ] **Step 1: Write the test**

```swift
// Tests/SyncFieldTests/SessionOrchestratorIngestTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorIngestTests: XCTestCase {
    func test_partial_ingest_failure_is_reported_not_raised() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let ok  = MockStream(streamId: "ok")
        let bad = MockStream(streamId: "bad")
        await bad.setFailAt(.ingest)
        try await s.add(ok)
        try await s.add(bad)

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        let report = try await s.ingest { _ in }

        if case .success = report.streamResults["ok"]! { /* ok */ } else { XCTFail() }
        if case .failure = report.streamResults["bad"]! { /* ok */ } else { XCTFail() }
    }
}
```

- [ ] **Step 2: Run, confirm PASS, commit**

```bash
git add Tests/SyncFieldTests/SessionOrchestratorIngestTests.swift
git commit -m "test: partial ingest failure surfaces per-stream, not as session failure"
```

---

## Phase 7: iPhone adapters

Tests in this phase are on-device only — they `#if !os(iOS)` skip. `swift test` on macOS remains green; the iPhone-targeted test suite runs in Xcode or `xcodebuild test -destination 'generic/platform=iOS Simulator'` (engineer provides simulator).

### Task 7.1: `iPhoneMotionStream`

**Files:**
- Create: `Sources/SyncField/Streams/iPhoneMotionStream.swift`
- Create: `Tests/SyncFieldTests/iPhoneMotionStreamTests.swift` (gated `#if os(iOS)`)

- [ ] **Step 1: Implement**

```swift
// Sources/SyncField/Streams/iPhoneMotionStream.swift
import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

public final class iPhoneMotionStream: Stream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false, supportsPreciseTimestamps: true)

    private let rateHz: Double
    private let queue = DispatchQueue(label: "syncfield.motion", qos: .userInitiated)

    private var writer: SensorWriter?
    private var clock: SessionClock?
    private var frameCount = 0
    private var healthBus: HealthBus?

    #if canImport(CoreMotion)
    private let manager = CMMotionManager()
    #endif

    public init(streamId: String, rateHz: Double = 100) {
        self.streamId = streamId
        self.rateHz = rateHz
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if canImport(CoreMotion)
        guard manager.isDeviceMotionAvailable else {
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.Motion",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "device motion unavailable"]))
        }
        manager.deviceMotionUpdateInterval = 1.0 / rateHz
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        self.writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.clock = clock
        self.frameCount = 0

        #if canImport(CoreMotion)
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: opQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if canImport(CoreMotion)
        manager.stopDeviceMotionUpdates()
        #endif
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
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    #if canImport(CoreMotion)
    private func handle(_ motion: CMDeviceMotion) {
        guard let clock = clock, let writer = writer else { return }
        let ticks = UInt64(motion.timestamp * Double(NSEC_PER_SEC))  // motion.timestamp is seconds since boot
        // NB: CMDeviceMotion.timestamp is mach-seconds already (monotonic), so scale to ns.
        let ns = ticks
        let frame = frameCount
        frameCount += 1

        let channels: [String: Any] = [
            "accel_x": motion.userAcceleration.x,
            "accel_y": motion.userAcceleration.y,
            "accel_z": motion.userAcceleration.z,
            "gyro_x":  motion.rotationRate.x,
            "gyro_y":  motion.rotationRate.y,
            "gyro_z":  motion.rotationRate.z,
            "gravity_x": motion.gravity.x,
            "gravity_y": motion.gravity.y,
            "gravity_z": motion.gravity.z,
        ]
        Task { [writer] in
            try? await writer.append(frame: frame, monotonicNs: ns,
                                     channels: channels,
                                     deviceTimestampNs: nil)
        }
    }
    #endif
}
```

- [ ] **Step 2: Device test**

```swift
// Tests/SyncFieldTests/iPhoneMotionStreamTests.swift
#if os(iOS)
import XCTest
@testable import SyncField

final class iPhoneMotionStreamTests: XCTestCase {
    func test_records_about_100_samples_per_second() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = iPhoneMotionStream(streamId: "imu", rateHz: 100)
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(stream)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(for: .seconds(1))
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let imu = stop.streamReports.first { $0.streamId == "imu" }!
        XCTAssertGreaterThan(imu.frameCount, 80)  // allow 20% scheduler jitter
    }
}
#endif
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncField/Streams/iPhoneMotionStream.swift Tests/SyncFieldTests/iPhoneMotionStreamTests.swift
git commit -m "feat: iPhoneMotionStream using CoreMotion device motion"
```

### Task 7.2: `iPhoneCameraStream` — capture + record

**Files:**
- Create: `Sources/SyncField/Streams/iPhoneCameraStream.swift`
- Create: `Tests/SyncFieldTests/iPhoneCameraStreamTests.swift` (gated `#if os(iOS)`)

- [ ] **Step 1: Implement (skeleton + capture-pipeline)**

This is AVFoundation boilerplate. The pattern:
1. `connect()`: configure `AVCaptureSession` with back camera + `AVCaptureVideoDataOutput`, add sample buffer delegate, call `session.startRunning()`. Expose the session for preview.
2. `startRecording(...)`: instantiate `AVAssetWriter` with H.264 video input, flip an internal `isRecording` flag, reset `frameCount`.
3. In `captureOutput(_:didOutput:from:)` delegate: always forward `CMSampleBuffer` to the (optional) frame processor. If `isRecording`, also append to `AVAssetWriter`, compute `monotonicNs` from `CMSampleBuffer.presentationTimeStamp`, and write a frame entry to the `StreamWriter`.
4. `stopRecording()`: set `isRecording = false`, `finishWriting` on the asset writer, close `StreamWriter`, return frame count.
5. `ingest(...)`: no-op (native — file is already on disk).
6. `disconnect()`: `session.stopRunning()`, publish disconnect event.

```swift
// Sources/SyncField/Streams/iPhoneCameraStream.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public final class iPhoneCameraStream: NSObject, Stream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: true, supportsPreciseTimestamps: true)

    #if canImport(AVFoundation)
    public let captureSession = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "syncfield.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var isRecording = false

    private var stampWriter: StreamWriter?
    private var clock: SessionClock?
    private var frameCount = 0
    private var startPTS: CMTime = .zero

    private var healthBus: HealthBus?

    private var frameProcessor: ((@Sendable (CMSampleBuffer, Int) -> Void))?
    private var throttleHz: Double = 0
    private var lastProcessorCall: CFAbsoluteTime = 0
    #endif

    public init(streamId: String) {
        self.streamId = streamId
        super.init()
    }

    public func prepare() async throws {}

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        #if canImport(AVFoundation)
        try configureSession()
        captureSession.startRunning()
        #endif
        await healthBus?.publish(.streamConnected(streamId: streamId))
    }

    #if canImport(AVFoundation)
    private func configureSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw StreamError(streamId: streamId,
                              underlying: NSError(domain: "SyncField.Camera",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "back camera not available"]))
        }
        captureSession.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

        captureSession.commitConfiguration()
    }
    #endif

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        #if canImport(AVFoundation)
        self.clock = clock
        self.frameCount = 0
        self.startPTS = .zero
        self.stampWriter = try writerFactory.makeStreamWriter(streamId: streamId)

        let url = writerFactory.videoURL(streamId: streamId)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        assetWriter = writer
        assetWriterInput = input
        isRecording = true
        writer.startWriting()
        #endif
    }

    public func stopRecording() async throws -> StreamStopReport {
        #if canImport(AVFoundation)
        isRecording = false
        assetWriterInput?.markAsFinished()
        if let w = assetWriter {
            await withCheckedContinuation { cont in
                w.finishWriting { cont.resume() }
            }
        }
        try await stampWriter?.close()
        let n = frameCount
        stampWriter = nil; assetWriter = nil; assetWriterInput = nil
        return StreamStopReport(streamId: streamId, frameCount: n, kind: "video")
        #else
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
        #endif
    }

    public func ingest(into dir: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).mp4",
                           frameCount: frameCount)
    }

    public func disconnect() async throws {
        #if canImport(AVFoundation)
        captureSession.stopRunning()
        #endif
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    // MARK: Frame processor hook

    public func setFrameProcessor(throttleHz: Double = 0,
                                  _ body: @escaping @Sendable (CMSampleBuffer, Int) -> Void) {
        #if canImport(AVFoundation)
        self.throttleHz = throttleHz
        self.frameProcessor = body
        #endif
    }
}

#if canImport(AVFoundation)
extension iPhoneCameraStream: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Frame processor (throttled)
        if let processor = frameProcessor {
            let now = CFAbsoluteTimeGetCurrent()
            let interval = throttleHz > 0 ? 1.0 / throttleHz : 0
            if now - lastProcessorCall >= interval {
                processor(sampleBuffer, frameCount)
                lastProcessorCall = now
            }
        }

        // Recording
        guard isRecording,
              let writer = assetWriter,
              let input = assetWriterInput,
              let clock = clock else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .zero {
            startPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            let monoNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)
            // Note: CMSampleBuffer PTS on the host comes from the session clock of the
            // CaptureSession, which is mach time. We convert via the SessionClock to the
            // monotonic ns domain used by every other stream.
            let frame = frameCount
            frameCount += 1
            let w = stampWriter
            Task {
                try? await w?.append(frame: frame,
                                     monotonicNs: clock.machTicksToMonotonicNs(
                                         UInt64(pts.value) * UInt64(1_000_000_000) / UInt64(pts.timescale)),
                                     uncertaintyNs: 1_000_000)
            }
            _ = monoNs  // keep for debug breakpoints
        }
    }
}
#endif
```

- [ ] **Step 2: Device test**

```swift
// Tests/SyncFieldTests/iPhoneCameraStreamTests.swift
#if os(iOS)
import XCTest
@testable import SyncField

final class iPhoneCameraStreamTests: XCTestCase {
    func test_produces_mp4_and_matching_timestamp_line_count() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego")
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(for: .seconds(2))
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let episodeDir = await s.episodeDirectory
        let mp4 = episodeDir.appendingPathComponent("cam_ego.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))

        let stamps = episodeDir.appendingPathComponent("cam_ego.timestamps.jsonl")
        let lines = try String(contentsOf: stamps).split(separator: "\n")
        let camReport = stop.streamReports.first { $0.streamId == "cam_ego" }!
        XCTAssertEqual(lines.count, camReport.frameCount)
    }
}
#endif
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncField/Streams/iPhoneCameraStream.swift Tests/SyncFieldTests/iPhoneCameraStreamTests.swift
git commit -m "feat: iPhoneCameraStream with AVFoundation capture + AVAssetWriter recording"
```

---

## Phase 8: `SyncFieldUIKit` preview helper

### Task 8.1: `SyncFieldPreviewView` (UIKit)

**Files:**
- Create: `Sources/SyncFieldUIKit/SyncFieldPreviewView.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/SyncFieldUIKit/SyncFieldPreviewView.swift
#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation
import SyncField

public final class SyncFieldPreviewView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    public init(stream: iPhoneCameraStream) {
        super.init(frame: .zero)
        previewLayer.session = stream.captureSession
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SyncFieldUIKit/SyncFieldPreviewView.swift
git commit -m "feat: SyncFieldPreviewView (UIKit) backed by AVCaptureVideoPreviewLayer"
```

### Task 8.2: `SyncFieldPreview` (SwiftUI)

**Files:**
- Create: `Sources/SyncFieldUIKit/SyncFieldPreview.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/SyncFieldUIKit/SyncFieldPreview.swift
#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
import SyncField

public struct SyncFieldPreview: UIViewRepresentable {
    private let stream: iPhoneCameraStream
    public init(stream: iPhoneCameraStream) { self.stream = stream }
    public func makeUIView(context: Context) -> SyncFieldPreviewView {
        SyncFieldPreviewView(stream: stream)
    }
    public func updateUIView(_ uiView: SyncFieldPreviewView, context: Context) {}
}
#endif
```

- [ ] **Step 2: Delete `Sources/SyncFieldUIKit/.gitkeep`, commit**

```bash
rm Sources/SyncFieldUIKit/.gitkeep
git add Sources/SyncFieldUIKit/SyncFieldPreview.swift Sources/SyncFieldUIKit/.gitkeep
git commit -m "feat: SyncFieldPreview (SwiftUI wrapper)"
```

---

## Phase 9: Verify the example compiles

### Task 9.1: Point the example at the real package

**Files:**
- Modify: `examples/egocentric-only/EgocentricViewController.swift`

The example file imports `SyncField` and `SyncFieldUIKit` which now exist. To actually compile-check it, create a thin SPM executable target under `examples/` that depends on the library.

- [ ] **Step 1: Add an `ExamplesCompileCheck` target**

Modify `Package.swift`:

```swift
// Append inside `targets:` array
.executableTarget(
    name: "ExamplesCompileCheck",
    dependencies: ["SyncField", "SyncFieldUIKit"],
    path: "examples",
    exclude: ["README.md", "ego-plus-wrist", "ego-plus-tactile"]  // require later plans' targets
),
```

Only `egocentric-only/` is compiled by Plan A. The other example directories are excluded until Plans B and C land.

Add a `main.swift` stub inside `examples/egocentric-only/` so SPM has an entry point:

```swift
// examples/egocentric-only/main.swift
#if os(iOS)
@main struct _ExamplesMain { static func main() {} }
#else
@main struct _ExamplesMain { static func main() { print("iOS-only example") } }
#endif
```

- [ ] **Step 2: Verify compile**

Run: `swift build --target ExamplesCompileCheck`
Expected: succeeds on macOS (the `#if os(iOS)` guards around AVFoundation code let macOS compile). If AVFoundation-using code needs to run, it only needs to *compile* on macOS via the canImport guards already in place.

- [ ] **Step 3: Commit**

```bash
git add Package.swift examples/egocentric-only/main.swift
git commit -m "chore: wire examples/egocentric-only into SPM for compile verification"
```

---

## Phase 10: Green-light checkpoint

### Task 10.1: Full test run

- [ ] **Step 1: Run the full test suite on macOS**

Run: `swift test`
Expected: all tests in Phases 1–6 pass. Phase 7 iOS tests are skipped at compile time by `#if os(iOS)`.

- [ ] **Step 2: Run the build for iOS Simulator**

Run: `xcodebuild -scheme SyncField -destination 'generic/platform=iOS Simulator' build`
Expected: compiles.

- [ ] **Step 3: Tag and announce**

```bash
git tag v0.2.0-plan-a
git log --oneline -20
```

- [ ] **Step 4: Confirm readiness for follow-on Plan B (Tactile)**

The `SessionOrchestrator`, `Stream`, `WriterFactory`, and `HealthBus` APIs are now frozen. Plan B implements `TactileStream` against them without touching core SDK code.

---

## Self-Review

**Spec coverage:**
- §2 Goals (record, 5-method lifecycle, stable customer contract, server-compatible episodes, Swift-native) → Phases 0–9 collectively.
- §3 Non-goals — no upload task, no viewer target, no multihost/chirp in this plan. ✓
- §4 Scope — Plan A covers egocentric-only end to end; ego+tactile and ego+wrist deferred to Plans B/C. ✓
- §5.1 Three targets — Phase 0 (Package.swift). ✓
- §5.2 5-phase lifecycle — Phase 6.1 (`require(state:next:)` + state transitions). ✓
- §5.3 Public types — Phases 1, 5, 6. ✓
- §5.4 Concurrency model — writers and orchestrator are actors (Phases 3, 6). ✓
- §5.5 Atomic start — Phase 6.2. ✓
- §5.6 Error handling — Phase 1.5 (`SessionError`, `StreamError`), Phase 6.3 (partial ingest failure test). ✓
- §6.1–6.2 iPhone adapters — Phase 7. ✓
- §6.3 Tactile — deferred to Plan B. (noted)
- §6.4 Insta360 — deferred to Plan C. (noted)
- §7 Episode format — Phases 3.4, 6.1 (manifest, sync_point), 6.1 (session.log). ✓
- §8 Testing strategy — unit tests in Phases 1–6, iOS-device tests in Phase 7, integration tests migrated in Plan D. ✓

**Placeholder scan:** No "TBD"/"TODO"/"fill in". Every step shows the code or command.

**Type consistency:**
- `SessionState` cases: used consistently in Phases 1, 6, 7. ✓
- `SyncPoint` field names: matches spec §7 verbatim. ✓
- `Stream` protocol signature: unchanged from Phase 5 through Phase 7. ✓
- `WriterFactory` method names (`makeStreamWriter`, `makeSensorWriter`, `videoURL`): used consistently in Phases 3.5, 7.1, 7.2. ✓
- `IngestReport.streamResults`: dict type consistent between Phase 6.1 and 6.3. ✓

**Gaps noted:** None that block this plan's execution. The `Stream` protocol requires streams expose `streamId` and `capabilities` as nonisolated — explicitly noted in Task 6.1 Step 1. Plans B, C, D are explicit follow-ons.

---

## Execution handoff

Plan is complete. Execute with superpowers:subagent-driven-development (recommended — fresh subagent per task with review between tasks) or superpowers:executing-plans (inline batch execution in the current session).
