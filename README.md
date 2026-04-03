# syncfield-swift

Lightweight Swift SDK for [SyncField](https://opengraphlabs.com) multi-stream synchronization. Captures precise timestamps during multi-camera and sensor recording and produces JSONL files that the SyncField Docker service consumes for frame-level temporal alignment.

## Install

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/OpenGraphLabs/syncfield-swift.git", from: "0.1.0"),
]
```

Or in Xcode: **File > Add Package Dependencies** > paste the repository URL.

**Zero dependencies** -- uses only the Swift standard library and Foundation.

## Quick Start

### Video Streams

Use `stamp()` to capture timestamps and `link()` to associate the saved video file with the stream.

```swift
import SyncField

let session = SyncSession(hostId: "iphone_01", outputDir: outputURL)
try session.start()

for i in 0..<numFrames {
    let frame = camera.read()
    try session.stamp("cam_ego", frameNumber: i)
    saveFrame(frame, to: "cam_ego.mp4")
}

session.link("cam_ego", path: "/data/cam_ego.mp4")
try session.stop()
```

Output:
```
sync_data/
  sync_point.json
  cam_ego.timestamps.jsonl
  manifest.json
```

### Sensor Streams

Use `record()` to capture timestamps and sensor data in one call. This writes both a `.timestamps.jsonl` file (for alignment) and a `.jsonl` file (sensor channel values).

```swift
import SyncField

let session = SyncSession(hostId: "iphone_01", outputDir: outputURL)
try session.start()

for i in 0..<numSamples {
    let data = imu.read()
    try session.record("imu", frameNumber: i, channels: [
        "accel_x": data.ax,
        "accel_y": data.ay,
        "accel_z": data.az,
    ])
}

try session.stop()
```

Output:
```
sync_data/
  sync_point.json
  imu.timestamps.jsonl
  imu.jsonl
  manifest.json
```

### Complex Sensor Data

Sensors like hand trackers, tactile arrays, and robot joints produce nested data. The SDK handles these natively -- leaf values must be numeric (`Double` or `Int`).

```swift
// Hand tracker -- nested joint positions and gestures
try session.record("hand_tracker", frameNumber: i, channels: [
    "joints": [
        "wrist": [0.1, 0.2, 0.3],
        "thumb_tip": [0.4, 0.5, 0.6],
        "index_tip": [0.7, 0.8, 0.9],
    ] as [String: Any],
    "gestures": ["pinch": 0.95, "fist": 0.02] as [String: Any],
    "finger_angles": [12.5, 45.0, 30.0, 15.0, 5.0],
])

// Tactile grid -- 2D pressure array
try session.record("tactile", frameNumber: i, channels: [
    "pressure_grid": [[0.1, 0.2, 0.3, 0.4],
                       [0.5, 0.6, 0.7, 0.8]],
    "total_force": 12.5,
])

// Robot arm -- joint states
try session.record("robot_arm", frameNumber: i, channels: [
    "joint_positions": [0.0, -1.57, 0.0, -1.57, 0.0, 0.0],
    "joint_velocities": [0.01, -0.02, 0.0, 0.01, 0.0, 0.0],
    "gripper": ["width": 0.04, "force": 5.2] as [String: Any],
])
```

SyncField automatically flattens nested channels for aggregation using dot-notation keys (e.g., `joints.wrist.0`, `gripper.width`).

### Multi-Stream Example

A complete example with 2 cameras and 1 IMU, each on its own DispatchQueue.

```swift
import SyncField

let session = SyncSession(hostId: "iphone_01", outputDir: outputURL)
try session.start()

var recording = true

func cameraLoop(cam: Camera, streamId: String, videoPath: String) {
    var i = 0
    while recording {
        let frame = cam.read()
        try? session.stamp(streamId, frameNumber: i)
        saveFrame(frame, to: videoPath)
        i += 1
    }
    session.link(streamId, path: videoPath)
}

func imuLoop(imu: IMU, streamId: String) {
    var i = 0
    while recording {
        let data = imu.read()
        try? session.record(streamId, frameNumber: i, channels: [
            "accel_x": data.ax, "accel_y": data.ay, "accel_z": data.az,
            "gyro_x": data.gx, "gyro_y": data.gy, "gyro_z": data.gz,
        ])
        i += 1
    }
}

let queue = DispatchQueue(label: "capture", attributes: .concurrent)
queue.async { cameraLoop(cam: camLeft, streamId: "cam_left", videoPath: "/data/cam_left.mp4") }
queue.async { cameraLoop(cam: camRight, streamId: "cam_right", videoPath: "/data/cam_right.mp4") }
queue.async { imuLoop(imu: imuDevice, streamId: "imu") }

// ... record for desired duration ...
recording = false

let counts = try session.stop()
// counts == ["cam_left": 900, "cam_right": 900, "imu": 9000]
```

Output directory:
```
sync_data/
  sync_point.json
  cam_left.timestamps.jsonl
  cam_right.timestamps.jsonl
  imu.timestamps.jsonl
  imu.jsonl
  manifest.json
```

## Best Practices

### Call `stamp()`/`record()` immediately after I/O read

The timestamp should reflect when data arrived on the host, not when processing finished.

```swift
// GOOD -- timestamp reflects when data arrived on the host
let data = device.read()
try session.stamp("sensor", frameNumber: i)  // immediately after read

// BAD -- processing delay adds jitter to timestamp
let data = device.read()
let processed = expensiveTransform(data)
try session.stamp("sensor", frameNumber: i)  // too late!
```

### Use one thread per device

Each device should have its own thread or DispatchQueue with a tight read loop. Both `stamp()` and `record()` are thread-safe.

```swift
let queue = DispatchQueue(label: "capture", attributes: .concurrent)

queue.async {
    var i = 0
    while recording {
        let frame = cam.read()
        try? session.stamp("cam_left", frameNumber: i)
        i += 1
    }
}

queue.async {
    var i = 0
    while recording {
        let data = imu.read()
        try? session.record("imu", frameNumber: i, channels: [
            "accel_x": data.ax, "accel_y": data.ay, "accel_z": data.az,
        ])
        i += 1
    }
}
```

### Pre-captured timestamps for minimum jitter

If your capture callback provides its own timestamp, pass it directly to avoid lock-acquisition delay:

```swift
let captureNs = MonotonicClock.now()  // capture immediately
// ... some unavoidable overhead ...
try session.stamp("cam", frameNumber: i, captureNs: captureNs)
```

## API Reference

### `SyncSession`

| Method | Description |
|--------|-------------|
| `init(hostId:outputDir:)` | Create a session. `outputDir` accepts `URL` or `String`. |
| `start() -> SyncPoint` | Begin recording. Captures the clock reference point. |
| `stamp(_:frameNumber:uncertaintyNs:captureNs:) -> UInt64` | Record a timestamp for one frame. |
| `record(_:frameNumber:channels:uncertaintyNs:captureNs:) -> UInt64` | Record timestamp + sensor data. |
| `link(_:path:)` | Associate an external file with a stream. |
| `stop() -> [String: Int]` | End session. Writes manifest and sync point. Returns frame counts. |

### Thread Safety

All methods are thread-safe. `stamp()` and `record()` can be called from multiple threads concurrently. The timestamp is captured *before* acquiring the internal lock, so lock contention does not affect timing precision.

### Timestamp Precision

Uses `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` for nanosecond-precision monotonic timestamps -- the iOS/macOS equivalent of Python's `time.monotonic_ns()`. This clock is not affected by NTP adjustments, ensuring consistent intervals for high-frequency capture.

## Integration with SyncField Docker

### Using `manifest.json` (recommended)

After `stop()`, the SDK writes a `manifest.json` that maps all streams to their files. Use it to construct the API request body programmatically.

```swift
import Foundation

let manifestData = try Data(contentsOf: outputURL.appendingPathComponent("manifest.json"))
let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]

let hostId = manifest["host_id"] as! String
let streamsMap = manifest["streams"] as! [String: [String: Any]]

var streams: [[String: Any]] = []
for (streamId, info) in streamsMap {
    var entry: [String: Any] = ["stream_id": streamId]
    if let path = info["path"] { entry["path"] = path }
    if info["type"] as? String == "sensor" { entry["stream_type"] = "sensor" }
    streams.append(entry)
}

// Mark first video as primary
if let idx = streams.firstIndex(where: {
    streamsMap[$0["stream_id"] as! String]?["type"] as? String == "video"
}) {
    streams[idx]["is_primary"] = true
}

let body: [String: Any] = [
    "hosts": [["host_id": hostId, "streams": streams]],
    "timestamps_dir": "/timestamps",
]
// POST to http://localhost:8080/api/v1/sync
```

### Volume-mounted mode

Mount your data and timestamp directories into the container and call the API directly.

```bash
docker run -v ./data:/data -v ./sync_data:/timestamps \
  syncfield-app:latest
```

```bash
curl -X POST http://localhost:8080/api/v1/sync \
  -H "Content-Type: application/json" \
  -d '{
    "hosts": [
      {
        "host_id": "iphone_01",
        "streams": [
          {"path": "/data/cam_ego.mp4", "stream_id": "cam_ego", "is_primary": true},
          {"path": "/data/cam_wrist.mp4", "stream_id": "cam_wrist"},
          {"stream_id": "imu", "stream_type": "sensor"}
        ]
      }
    ],
    "timestamps_dir": "/timestamps"
  }'
```

The service automatically matches `{stream_id}.timestamps.jsonl` and `{stream_id}.jsonl` files to streams using the `timestamps_dir` path.

### File upload mode

Upload files directly without volume mounts.

```bash
curl -X POST http://localhost:8080/api/v1/sync/upload \
  -F "files=@cam_ego.mp4" \
  -F "files=@cam_wrist.mp4" \
  -F "timestamp_files=@sync_data/cam_ego.timestamps.jsonl" \
  -F "timestamp_files=@sync_data/cam_wrist.timestamps.jsonl" \
  -F "stream_ids=cam_ego,cam_wrist" \
  -F "host_ids=iphone_01,iphone_01" \
  -F "primary_id=cam_ego"
```

## Format Specification

This section defines the output format for implementors in other languages.

### `sync_point.json`

```json
{
  "sdk_version": "0.1.0",
  "monotonic_ns": 1234567890123456789,
  "wall_clock_ns": 1709890101000000000,
  "host_id": "iphone_01",
  "timestamp_ms": 1709890101000,
  "iso_datetime": "2024-03-08T12:00:01.000000"
}
```

### `{stream_id}.timestamps.jsonl`

One JSON object per line (no trailing comma, no array wrapper):

```jsonl
{"capture_ns":1234567890123456789,"clock_domain":"iphone_01","clock_source":"host_monotonic","frame_number":0,"uncertainty_ns":5000000}
{"capture_ns":1234567890156789012,"clock_domain":"iphone_01","clock_source":"host_monotonic","frame_number":1,"uncertainty_ns":5000000}
```

| Field | Type | Description |
|-------|------|-------------|
| `frame_number` | int | 0-based sequential index |
| `capture_ns` | int | Monotonic nanoseconds at data arrival |
| `clock_source` | string | Always `"host_monotonic"` for SDK output |
| `clock_domain` | string | Must match `host_id` -- identifies the clock |
| `uncertainty_ns` | int | Timing uncertainty (default: 5000000 = 5ms) |

**Key rules:**
- `capture_ns` must be monotonically non-decreasing within each stream
- `clock_domain` must be identical across all streams on the same host
- File name must be `{stream_id}.timestamps.jsonl` for auto-matching

### `{stream_id}.jsonl` (Sensor Data)

One JSON object per line, combining timestamp and channel values:

```jsonl
{"capture_ns":1234567890123456789,"channels":{"accel_x":0.12,"accel_y":-9.8,"accel_z":0.05},"clock_domain":"iphone_01","clock_source":"host_monotonic","frame_number":0,"uncertainty_ns":5000000}
```

| Field | Type | Description |
|-------|------|-------------|
| `frame_number` | int | 0-based sequential index |
| `capture_ns` | int | Monotonic nanoseconds at data arrival (same clock as video timestamps) |
| `clock_source` | string | Origin of the timestamp (always `"host_monotonic"` for SDK) |
| `clock_domain` | string | Host identifier -- must match across all streams on the same host |
| `uncertainty_ns` | int | Timing uncertainty (default: 5000000 = 5ms) |
| `channels` | object | Sensor values as key-value pairs (e.g. `{"accel_x": 0.12}`) |

### `manifest.json`

Written by `stop()`. Maps all streams in the session to their output files.

```json
{
  "sdk_version": "0.1.0",
  "host_id": "iphone_01",
  "streams": {
    "cam_ego": {
      "type": "video",
      "timestamps_path": "cam_ego.timestamps.jsonl",
      "frame_count": 900,
      "path": "/data/cam_ego.mp4"
    },
    "cam_wrist": {
      "type": "video",
      "timestamps_path": "cam_wrist.timestamps.jsonl",
      "frame_count": 900,
      "path": "/data/cam_wrist.mp4"
    },
    "imu": {
      "type": "sensor",
      "sensor_path": "imu.jsonl",
      "timestamps_path": "imu.timestamps.jsonl",
      "frame_count": 9000
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `sdk_version` | string | SDK version that produced this file |
| `host_id` | string | Host identifier for this recording session |
| `streams` | object | Map of `stream_id` to stream metadata |
| `streams.*.type` | string | `"video"` or `"sensor"` |
| `streams.*.timestamps_path` | string | Relative path to the timestamps JSONL file |
| `streams.*.frame_count` | int | Number of frames/samples recorded |
| `streams.*.path` | string | (video only) Path set via `link()` |
| `streams.*.sensor_path` | string | (sensor only) Relative path to the sensor data JSONL file |

## Platforms

- iOS 15+
- macOS 12+

## License

Apache-2.0
