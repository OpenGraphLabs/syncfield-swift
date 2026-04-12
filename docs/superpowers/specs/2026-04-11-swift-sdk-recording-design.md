# syncfield-swift v0.2 — Recording-Capable SDK

**Date:** 2026-04-11
**Status:** Approved for implementation
**Breaking change:** yes — v0.2 is not source-compatible with v0.1

## 1. Context

syncfield-python v0.2 evolved from a timestamping-only helper into a full recording orchestrator (device I/O + atomic multi-stream start + crash-safe persistence + live preview). The current syncfield-swift v0.1 stopped at timestamping, so every iOS integration (egonaut mobile app) re-implements AVFoundation capture, BLE device control, and episode-file layout by hand. This document specifies the v0.2 Swift SDK that absorbs those responsibilities for the three iOS use cases the egonaut app ships today.

## 2. Goals

- **Record, not just stamp.** SDK owns device I/O, file writing, and session metadata.
- **One lifecycle for every configuration.** The same five calls work whether you record iPhone-only, iPhone + Insta360, or iPhone + tactile gloves.
- **Stable customer contract.** Integration is 5–10 lines of Swift. Adding or removing a device is one `session.add(...)` line.
- **Produce episodes the existing syncfield server already understands.** No server-side changes required.
- **Swift-native ergonomics.** async/await, actors, Swift concurrency. No RN assumptions in the core SDK.

## 3. Non-goals (explicit cuts)

- **Upload / sync job submission.** Customers own their storage and auth; the SDK produces a self-contained episode directory and stops there.
- **Live preview web UI (Python's `viewer/`).** Customers build their own preview UI with the provided `AVCaptureSession` or the `SyncFieldUIKit` helper.
- **Multi-host sessions and audio chirp.** Out of scope for v0.2; may land later behind a separate target.
- **Backwards compatibility with v0.1.** Callers will migrate on upgrade; no shims.

## 4. Scope — three reference integrations

| Configuration | Streams | Ingest? |
|---|---|---|
| egocentric-only | `iPhoneCameraStream`, `iPhoneMotionStream` | no-op |
| ego + wrist | + `Insta360CameraStream` | BLE stop + WiFi download |
| ego + tactile | + `TactileStream` × 2 (L/R, BLE) | no-op |

Integration examples are the contract — see `examples/` for the exact API surface customers see.

## 5. Architecture

### 5.1 Swift Package layout

```
Package: syncfield-swift
├── SyncField                ← core: no external deps (Foundation, AVFoundation,
│                              CoreMotion, CoreBluetooth)
├── SyncFieldUIKit           ← optional: SwiftUI/UIKit preview helper
├── SyncFieldInsta360        ← optional: depends on Insta360 SDK xcframeworks
│                              (customer supplies binaries)
└── SyncFieldTests
```

Keeping Insta360 in its own target means customers without wrist-camera support don't pull the Insta360 SDK dependency.

### 5.2 5-phase lifecycle

```
 IDLE ──connect()──▶ CONNECTED ──startRecording()──▶ RECORDING
                       ▲                                   │
                       │                           stopRecording()
                   disconnect()                            │
                       │                                   ▼
                       │                              STOPPING
                       │                                   │
                       │                          ingest(progress:)
                       │                                   ▼
                       └──────────────────────────── INGESTING
                                                           │
                                                     (ingest done)
                                                           ▼
                                                       CONNECTED
```

- `CONNECTED` = devices open, preview live, no files being written.
- `ingest()` handles post-recording work (Insta360 WiFi download). For native streams it is a no-op.
- After `ingest()` finishes the session returns to `CONNECTED` — the customer can start another recording in the same session.

### 5.3 Public core types

```swift
public actor SessionOrchestrator {
    public init(hostId: String, outputDirectory: URL)
    public var state: SessionState { get }
    public var episodeDirectory: URL { get }
    public var healthEvents: AsyncStream<HealthEvent> { get }

    public func add(_ stream: any Stream) throws
    public func connect() async throws
    public func startRecording(countdown: Duration = .zero) async throws -> SyncPoint
    public func stopRecording() async throws -> StopReport
    public func ingest(progress: @Sendable (IngestProgress) -> Void) async throws -> IngestReport
    public func disconnect() async throws
}

public protocol Stream: Sendable {
    var streamId: String { get }
    var capabilities: StreamCapabilities { get }

    func prepare() async throws
    func connect(context: StreamConnectContext) async throws
    func startRecording(clock: SessionClock,
                        writerFactory: WriterFactory) async throws
    func stopRecording() async throws -> StreamStopReport
    func ingest(into episodeDirectory: URL,
                progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport
    func disconnect() async throws
}

public struct SyncPoint: Codable, Sendable {
    public let sdkVersion: String
    public let monotonicNs: UInt64
    public let wallClockNs: UInt64
    public let hostId: String
    public let isoDatetime: String
}

public enum HealthEvent: Sendable {
    case streamConnected(streamId: String)
    case streamDisconnected(streamId: String, reason: String)
    case samplesDropped(streamId: String, count: Int)
    case ingestProgress(streamId: String, fraction: Double)
    case ingestFailed(streamId: String, error: Error)
}
```

### 5.4 Concurrency model

- `SessionOrchestrator` is an **actor** — all state transitions serialized.
- File writers (`StreamWriter`, `SensorWriter`, `SessionLogWriter`) are internal actors guarding their file handles.
- Device callbacks (CoreBluetooth delegate, `AVCaptureVideoDataOutputSampleBufferDelegate`) arrive on their native `DispatchQueue`s; streams hop to the writer actor via `Task { await writer.append(...) }`. The existing Tactile 100 Hz path demonstrates this overhead is acceptable.
- `HealthEvent`s are broadcast through a single `AsyncStream` fan-out (ring-buffered, bounded to drop oldest if unread).

### 5.5 Atomic start with rollback

`startRecording()` calls `stream.startRecording(...)` on all registered streams concurrently. If any one throws, the orchestrator calls compensating `stopRecording()` on the streams that already started and deletes any files they created, then rethrows a `SessionError.startFailed(cause:rolledBack:)`. Mirror of `syncfield-python/src/syncfield/orchestrator.py` atomic-start behaviour.

### 5.6 Error handling

- Errors are thrown, not Result-returned (Swift convention).
- `SessionError` (lifecycle violations, rollback outcomes) and `StreamError` (stream-attributed) — `StreamError` always carries `streamId` so the caller knows which device failed.
- `ingest()` returns an `IngestReport` with `streamResults: [String: Result<StreamIngestReport, Error>]` — **partial ingest failure does not abort the whole call**, because the Insta360 WiFi download failing should not invalidate iPhone or tactile data already on disk.

## 6. Built-in Stream adapters

### 6.1 `iPhoneCameraStream`

- Wraps a dedicated `AVCaptureSession` owned by the stream.
- Capture path: single `AVCaptureVideoDataOutput` → `CMSampleBuffer`
  - in `CONNECTED`: forwarded only to preview + optional frame processor.
  - in `RECORDING`: additionally fed to `AVAssetWriter` (H.264, .mp4). Using data-output+writer instead of `AVCaptureMovieFileOutput` avoids the "cannot run movie file output and data output together" constraint.
- Frame PTS (`CMSampleBuffer.presentationTimeStamp`) is converted to session monotonic ns via the capture clock, then persisted to `{streamId}.timestamps.jsonl`.
- Optional `setFrameProcessor(throttleHz:_:)` exposed on the stream (not on the session). Throttle logic (default 10 Hz, matches current egonaut hand-detection throttle at `HandDetectionFrameProcessor.swift:14`) lives in the SDK.
- Public access to `captureSession` (read-only) for customers who need a fully custom preview.

### 6.2 `iPhoneMotionStream`

- `CMMotionManager` with fused device motion (accelerometer + gyro + magnetometer) at configurable `rateHz` (default 100).
- Each sample: `{frame, timestamp_ns, channels: {accel_x,...}}` → `{streamId}.jsonl`.
- Uses `CMDeviceMotion.timestamp` mapped through `mach_absolute_time`-to-monotonic conversion (CoreMotion timestamps are mach ticks, not wall).

### 6.3 `TactileStream(side:)`

- Absorbs the existing `TactileGloveManager` (`/Users/jerry/Documents/egonaut/mobile/ios/EgonautMobile/Tactile/TactileGloveManager.swift`) logic into the SDK.
- `CoreBluetooth` central scan with Oglo service UUID (from `TactileConstants.swift`), side selection by advertising data.
- 100 Hz notify stream; each packet parsed to 5 FSR channels + device hw timestamp (`device_timestamp_ns`) → `{streamId}.jsonl`.
- `connect()` blocks until the specific side is discovered + paired; timeout configurable (default 15s).
- Emits `HealthEvent.streamDisconnected(reason: "ble_connection_lost")` on peripheral disconnect.

### 6.4 `Insta360CameraStream` (in `SyncFieldInsta360` target)

- Absorbs `Insta360CameraManager` and `Insta360WiFiTransferManager` from egonaut.
- `connect()`: BLE discover + pair (INSCameraSDK).
- `startRecording()`: BLE command to begin remote recording on the camera itself; stream records only a manifest entry noting the camera timestamp of "start" (host monotonic for the BLE ACK).
- `stopRecording()`: BLE stop command, capture camera-reported start/stop timestamps.
- `ingest(into:progress:)`: switches device to camera's WiFi AP, downloads the mp4 via the INSCameraSDK transfer API, copies into episode directory, writes `cam_wrist.timestamps.jsonl` by mapping camera PTS to session monotonic via the BLE-ACK anchor. Reports progress fractionally.
- Cancellation: `Task.cancel()` on the ingest task aborts the download; the partial file is removed.

## 7. Episode output format

Identical to syncfield-python v0.2 and to what syncfield server expects:

```
<outputDirectory>/ep_<UTC-timestamp>_<shortId>/
├── manifest.json          ← sdk_version, host_id, role="single", streams: [...]
├── sync_point.json        ← monotonic_ns + wall_clock_ns anchor
├── session.log            ← line-flushed state transitions + health events
├── <streamId>.mp4         ← for video streams
├── <streamId>.timestamps.jsonl
└── <streamId>.jsonl       ← for sensor streams
```

JSON field names and semantics match the [swift docs spec](../../../syncfield/website/docs/sdk/swift.md) verbatim so no server changes are needed.

## 8. Testing strategy

Two tiers:

### 8.1 Unit tests (`SyncFieldTests`, on any macOS runner)

- `SessionClock`: monotonic/wall-clock anchor, unit-convertible.
- `SessionOrchestrator` state machine: legal/illegal transitions, each phase's preconditions.
- Atomic start rollback: a failing mock stream causes the successful ones to be stopped + their files removed.
- `StreamWriter`, `SensorWriter`: JSONL round-trip, line-flush, crash-resilience (partial line on abrupt close is ≤ 1 line).
- `SessionLogWriter`: every transition flushed before return.
- `HealthBus`: fan-out to multiple subscribers, bounded buffer drops oldest not newest.
- `Ingest partial-failure`: one stream throws, other streams still produce valid reports.
- Mock `Stream` implementations for all of the above — no real devices required.

### 8.2 Integration tests (`SyncFieldDeviceTests`, iOS-device only)

- `iPhoneCameraStream`: 5-second record produces a playable mp4 whose PTS matches the JSONL timestamps.
- `iPhoneMotionStream`: 1-second record at 100 Hz produces ≥ 95 samples (allow scheduler jitter).
- `TactileStream`: opt-in — requires a physical glove.
- `Insta360CameraStream`: opt-in — requires a physical camera.

Migrate the existing `EgonautMobileTests/SyncFieldIntegrationTests.swift` assertions (concurrent Tactile+IMU writes, manifest correctness, dual-timestamp dual-recording) into the SDK test target so they run as part of SDK CI.

### 8.3 CI

- `swift test` on macOS runner runs 8.1 every PR.
- 8.2 runs nightly or on-demand on an iOS device runner.

## 9. egonaut migration

Breaking migration (per customer direction). After SDK v0.2 is tagged:

1. Bump `syncfield-swift` dependency in egonaut's iOS target to v0.2.
2. Delete `EgonautMobile/SyncField/SyncFieldManager.swift` (replaced by `SessionOrchestrator`).
3. Rewrite `SyncFieldBridgeModule` as a thin RN wrapper over `SessionOrchestrator`:
   - `start(hostId, outputDir)` → `connect() + startRecording()`
   - `stop()` → `stopRecording() + ingest() + disconnect()` (or expose ingest progress to JS)
   - Drop `stamp()` / `record()` from the RN surface — frames are now captured natively.
4. Delete `Tactile/TactileGloveManager.swift`, `Tactile/TactileBridgeModule.swift` — replaced by `TactileStream` plus a minimal RN status bridge that subscribes to `session.healthEvents`.
5. Delete `Insta360/Insta360CameraManager.swift`, `Insta360WiFiTransferBridge.swift`, `Insta360WiFiTransferManager.swift` — replaced by `Insta360CameraStream` in the SDK.
6. Delete `HandDetectionFrameProcessor.swift` (vision-camera plugin) and the `react-native-vision-camera` dependency. Attach the Vision/CoreML hand-detection logic to `iPhoneCameraStream.setFrameProcessor`.
7. Delete `react-native-sensors` dependency. CoreMotion is now in-SDK.
8. RN UI stays in JS; it calls the reduced bridge surface (`start/stop/healthEvent emitter`) and shows preview via a Native component wrapping `SyncFieldPreviewView`.

Net egonaut change: ~1500 LOC of native Swift removed, ~100 LOC of bridge remains. RN/JS business logic unchanged except for the call surface.

## 10. Open items (decided during implementation, not blockers)

- Naming of `SessionOrchestrator` vs `RecordingSession`: using `SessionOrchestrator` to match Python SDK. Customers see this name in ~5 places.
- `HealthBus` buffer size: start at 64, tune if egonaut integration surfaces drops.
- Whether `Stream` protocol should include a `snapshot()` for still capture: defer to v0.3.

## 11. Implementation sequencing

Handed off to the `writing-plans` skill. High-level phases:

1. Core skeleton: `SessionOrchestrator`, `SessionClock`, `SyncPoint`, Writers, `HealthBus`, `Stream` protocol, state machine, atomic start.
2. `iPhoneCameraStream` + `iPhoneMotionStream` + `SyncFieldUIKit` preview target.
3. `TactileStream` (port from egonaut).
4. `Insta360CameraStream` in separate target (port from egonaut).
5. Examples compile-check (separate SPM target that imports all three).
6. egonaut migration PR (separate repo, separate PR).

Each phase ships with its own tests and a green `swift test` run before the next phase starts.
