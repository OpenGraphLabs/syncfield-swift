# syncfield-swift

Swift SDK for [SyncField](https://opengraphlabs.com) multi-stream synchronized recording on iOS. Captures iPhone camera, IMU, BLE tactile gloves, and (optionally) Insta360 Go 3S, all stamped against a single host-monotonic clock and packaged into a self-contained episode directory the SyncField sync server can ingest directly.

- **Zero third-party dependencies** in the core (`SyncField`) — Foundation, AVFoundation, CoreMotion, CoreBluetooth only.
- **Modular** — link only what you need. Tactile and Insta360 paths are isolated in their own targets.
- **Modern Swift Concurrency** — `actor`-based session orchestrator, `AsyncStream` health events, full `Sendable` conformance.

## Modules

| Product | Purpose | Required dependencies |
|---|---|---|
| `SyncField` | Core. Session orchestrator + iPhone camera/IMU + Oglo tactile gloves. | None (system frameworks only) |
| `SyncFieldUIKit` | `UIView` / SwiftUI camera preview helpers. | None |
| `SyncFieldInsta360` | **Optional.** Insta360 Go 3S BLE-trigger + WiFi download. | `INSCameraServiceSDK.xcframework` from Insta360 — see [`docs/insta360.md`](docs/insta360.md) |

## Install

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/OpenGraphLabs/syncfield-swift.git", from: "0.7.4"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SyncField",        package: "syncfield-swift"),
            .product(name: "SyncFieldUIKit",   package: "syncfield-swift"), // optional
            .product(name: "SyncFieldInsta360", package: "syncfield-swift"), // optional, see docs/insta360.md
        ]),
]
```

Or in Xcode: **File ▸ Add Package Dependencies** ▸ paste `https://github.com/OpenGraphLabs/syncfield-swift.git`.

### Info.plist permissions

Add the keys for the streams you actually use.

| Stream | Required Info.plist keys |
|---|---|
| `iPhoneCameraStream` | `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` |
| `iPhoneMotionStream` | `NSMotionUsageDescription` |
| `TactileStream` | `NSBluetoothAlwaysUsageDescription` |
| `Insta360CameraStream` | `NSBluetoothAlwaysUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSLocalNetworkUsageDescription`, plus the **Hotspot Configuration** capability |

A `PrivacyInfo.xcprivacy` manifest is shipped inside each target — your App Store submission inherits it automatically.

## Quick start — iPhone camera + IMU

```swift
import SyncField
import SyncFieldUIKit

let cam = iPhoneCameraStream(streamId: "cam_ego")
let imu = iPhoneMotionStream(streamId: "imu", rateHz: 100)

let session = SessionOrchestrator(
    hostId: "iphone_ego",
    outputDirectory: episodesDir)

try await session.add(cam)
try await session.add(imu)

try await session.connect()           // open camera + IMU; preview is live
try await session.startRecording()    // atomic start of all streams
//   ... user records ...
_ = try await session.stopRecording() // close files
_ = try await session.ingest { _ in } // post-recording imports (no-op for native streams)
try await session.disconnect()        // release devices

// session.episodeDirectory now holds the episode. Ship it to your storage.
```

Live camera preview (UIKit):

```swift
let preview = SyncFieldPreviewView(stream: cam)
view.addSubview(preview)
```

Or SwiftUI:

```swift
SyncFieldPreview(stream: cam)
```

## The lifecycle

Every recording follows the same five-method cycle. Adding or removing streams is the only thing that changes between setups.

```
idle ──add()──▶ idle ──connect()──▶ connected ──startRecording()──▶ recording
                                       ▲                                │
                                       │                          stopRecording()
                                       │                                ▼
                                  disconnect()                      stopping
                                       │                                │
                                       │                            ingest()
                                       │                                ▼
                                       └──────────────────────────  ingesting ─┐
                                                                                │
                                                                               (back to connected)
```

See [`docs/integration.md`](docs/integration.md) for the host-app patterns that exercise this state machine — deferred-connect for late-attached streams, ingest skipping, custom chirp configuration, and health-event subscription.

## Recipes

Three reference integrations under [`examples/`](examples) cover the common iOS rigs. Each is one self-contained `UIViewController`.

| Setup | Streams | Path |
|---|---|---|
| Egocentric only | iPhone camera + IMU | [`examples/egocentric-only/`](examples/egocentric-only) |
| Egocentric + tactile | iPhone camera + IMU + Oglo gloves (L/R) | [`examples/ego-plus-tactile/`](examples/ego-plus-tactile) |
| Egocentric + wrist | iPhone camera + IMU + Insta360 Go 3S | [`examples/ego-plus-wrist/`](examples/ego-plus-wrist) |

## Streams

### `iPhoneCameraStream`

H.264 / HEVC mp4 with embedded mic audio track. Audio is the carrier for SyncField's chirp-based cross-host alignment.

```swift
// 1080 p @ 30 fps default
let cam = iPhoneCameraStream(streamId: "cam_ego")

// Or pick a preset
let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720_60)

// Or build your own
let cam = iPhoneCameraStream(
    streamId: "cam_ego",
    videoSettings: VideoSettings(width: 1280, height: 720,
                                 codec: .hevc,
                                 bitrate: 6_000_000,
                                 fps: 60))
```

Built-in presets: `.hd720`, `.hd720_60`, `.fullHD`, `.uhd4K`. Unsupported (resolution, fps) combinations gracefully fall back to the highest fps the format supports — capture never fails because of a fps mismatch.

### `iPhoneMotionStream`

CoreMotion device motion at the requested rate (default 100 Hz). Writes user acceleration, rotation rate, and gravity to a single sensor JSONL.

```swift
let imu = iPhoneMotionStream(streamId: "imu", rateHz: 100)
```

### `TactileStream`

BLE-connected Oglo tactile glove (5 FSR channels @ 100 Hz with firmware-side hardware timestamps). One stream per glove side.

```swift
let left  = TactileStream(streamId: "tactile_left",  side: .left)
let right = TactileStream(streamId: "tactile_right", side: .right)

// Optional: subscribe to live samples for UI / gesture preview
left.setSampleHandler { event in
    // event.channels: [String: Int] (raw 12-bit FSR), event.frame, event.monotonicNs
}
```

### `Insta360CameraStream` (optional module)

BLE-trigger + WiFi-download path for the Insta360 Go 3S wrist camera. **Requires `INSCameraServiceSDK.xcframework` to be linked into your host app.** When the framework is missing, every method throws `Insta360Error.frameworkNotLinked` — the rest of SyncField is unaffected.

```swift
import SyncFieldInsta360

let wrist = Insta360CameraStream(streamId: "cam_wrist")
try await session.add(wrist)
// ... ingest() automatically switches to the camera AP, downloads the clip, restores WiFi.
```

Full setup — obtaining the framework, embedding it, the BLE/WiFi flow — is documented in [`docs/insta360.md`](docs/insta360.md).

## Episode directory

Every session writes a timestamped directory under `outputDirectory`:

```
episodes/
└── ep_20260411_152930_abc123/
    ├── manifest.json           # stream catalogue
    ├── sync_point.json         # monotonic⇄wall-clock anchor + chirp markers
    ├── session.log             # state-machine transitions
    ├── cam_ego.mp4
    ├── cam_ego.timestamps.jsonl
    ├── imu.jsonl
    ├── tactile_left.jsonl              (when present)
    ├── tactile_right.jsonl             (when present)
    ├── cam_wrist.mp4                   (when present)
    └── cam_wrist.anchor.json           (BLE-ACK anchor — Insta360)
```

The SDK does **not** upload — that's intentionally left to the host app. After `disconnect()`, ship `session.episodeDirectory` to your storage.

## Output format reference

### `sync_point.json`

```json
{
  "sdk_version": "0.3.0",
  "monotonic_ns": 1234567890123456789,
  "wall_clock_ns": 1709890101000000000,
  "host_id": "iphone_ego",
  "iso_datetime": "2026-04-11T15:29:30.000000Z",
  "chirp_start_ns": 1234567890200000000,
  "chirp_stop_ns":  1234567892800000000,
  "chirp_start_source": "audio_engine",
  "chirp_stop_source":  "audio_engine"
}
```

### `{stream_id}.timestamps.jsonl` (camera streams)

One JSON object per line, no array wrapper:

```jsonl
{"capture_ns":1234567890123456789,"clock_domain":"iphone_ego","clock_source":"host_monotonic","frame_number":0,"uncertainty_ns":1000000}
{"capture_ns":1234567890156789012,"clock_domain":"iphone_ego","clock_source":"host_monotonic","frame_number":1,"uncertainty_ns":1000000}
```

| Field | Type | Description |
|---|---|---|
| `frame_number` | int | 0-based |
| `capture_ns` | int | Host monotonic ns at sample arrival; non-decreasing within a stream |
| `clock_source` | string | Always `"host_monotonic"` for the iPhone |
| `clock_domain` | string | Equals `host_id` |
| `uncertainty_ns` | int | Camera path: 1 ms; sensors: 5 ms |

### `{stream_id}.jsonl` (sensor streams)

```jsonl
{"capture_ns":1234567890123456789,"channels":{"accel_x":0.12,"accel_y":-9.8,"accel_z":0.05},"clock_domain":"iphone_ego","clock_source":"host_monotonic","frame_number":0,"uncertainty_ns":5000000}
```

The `channels` object is sensor-specific. For the tactile glove the labels come from the firmware manifest (`thumb`, `index`, `middle`, `ring`, `pinky`); for IMU it's `accel_x/y/z`, `gyro_x/y/z`, `gravity_x/y/z`.

### `manifest.json`

Written by the orchestrator at `stopRecording()` (and again at `ingest()`). Maps every registered stream to its output file plus capability flags:

```json
{
  "sdk_version": "0.3.0",
  "host_id": "iphone_ego",
  "role": "single",
  "streams": [
    {
      "stream_id": "cam_ego",
      "kind": "video",
      "file_path": "cam_ego.mp4",
      "frame_count": 900,
      "capabilities": {
        "produces_file": true,
        "supports_precise_timestamps": true,
        "provides_audio_track": true,
        "requires_ingest": false
      }
    }
  ]
}
```

## Sending an episode to the SyncField sync server

After `disconnect()`, post the directory to your SyncField deployment. Two flavours:

### Volume-mounted

```bash
docker run -v ./episodes/ep_20260411_152930_abc123:/data \
           -v ./episodes/ep_20260411_152930_abc123:/timestamps \
           syncfield-app:latest

curl -X POST http://localhost:8080/api/v1/sync \
  -H "Content-Type: application/json" \
  -d '{
    "hosts": [
      {
        "host_id": "iphone_ego",
        "streams": [
          {"path": "/data/cam_ego.mp4", "stream_id": "cam_ego", "is_primary": true},
          {"stream_id": "imu", "stream_type": "sensor"}
        ]
      }
    ],
    "timestamps_dir": "/timestamps"
  }'
```

### File upload

```bash
curl -X POST http://localhost:8080/api/v1/sync/upload \
  -F "files=@cam_ego.mp4" \
  -F "timestamp_files=@cam_ego.timestamps.jsonl" \
  -F "timestamp_files=@imu.jsonl" \
  -F "stream_ids=cam_ego,imu" \
  -F "host_ids=iphone_ego,iphone_ego" \
  -F "primary_id=cam_ego"
```

The `manifest.json` produced by the SDK is the authoritative catalogue — you can also generate the request body programmatically by reading it.

## Documentation

- [`examples/`](examples) — three copy-pasteable view controllers
- [`docs/integration.md`](docs/integration.md) — lifecycle, host-app patterns, health events, custom chirp
- [`docs/insta360.md`](docs/insta360.md) — Insta360 framework setup and ingest flow
- [`CHANGELOG.md`](CHANGELOG.md)

## Platforms

- iOS 15+ (primary; all streams)
- macOS 12+ (core only — camera/motion/Bluetooth disabled at compile time)

## Thread safety

`SessionOrchestrator` is an `actor`. Streams are individually `Sendable` and safe to call from any task; per-stream internal queues serialise device I/O. Health events flow through `AsyncStream<HealthEvent>` returned by `session.healthEvents`.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
