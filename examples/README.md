# Integration Examples

Three reference integrations showing how to use **syncfield-swift** for the common iOS recording setups. Copy-paste the view controller into your app and adapt.

| Example | Streams captured |
|---|---|
| [`egocentric-only/`](./egocentric-only) | iPhone back camera + CoreMotion IMU |
| [`ego-plus-wrist/`](./ego-plus-wrist) | iPhone camera + IMU + Insta360 Go 3S (BLE trigger, WiFi download) |
| [`ego-plus-tactile/`](./ego-plus-tactile) | iPhone camera + IMU + Oglo tactile gloves (left + right, BLE) |

## The integration pattern

Every setup uses the same five-method lifecycle. Changing what you record means adding or removing `Stream` instances — nothing else changes.

```swift
let session = SessionOrchestrator(hostId: "my_rig",
                                  outputDirectory: episodesDir)
try session.add(iPhoneCameraStream(streamId: "cam_ego"))
try session.add(iPhoneMotionStream(streamId: "imu"))

try await session.connect()           // open devices, preview ready
try await session.startRecording()    // start writing files
//   ... user interaction ...
_ = try await session.stopRecording() // stop writing, close files
_ = try await session.ingest { _ in } // post-recording imports (e.g. WiFi download)
try await session.disconnect()        // release devices

// session.episodeDirectory now holds a self-contained episode.
// Upload it to your own storage — the SDK does not handle uploads.
```

## What the SDK does / doesn't do

- **Does**: capture device I/O, stamp frames against a shared monotonic clock, write JSONL + video files, produce a self-contained episode directory compatible with the `syncfield` sync server.
- **Doesn't**: upload. After `disconnect()`, ship `session.episodeDirectory` to your own storage (S3/GCS/internal API). How and when to upload is intentionally left to you.

## Episode directory layout

Every session produces a timestamped directory under `outputDirectory`:

```
episodes/
└── ep_20260411_152930_abc123/
    ├── manifest.json
    ├── sync_point.json
    ├── session.log
    ├── cam_ego.mp4
    ├── cam_ego.timestamps.jsonl
    ├── imu.jsonl
    ├── cam_wrist.mp4                  (ego-plus-wrist only)
    ├── cam_wrist.timestamps.jsonl
    ├── tactile_left.jsonl             (ego-plus-tactile only)
    └── tactile_right.jsonl
```

This is the exact format the `syncfield` sync server consumes via `POST /api/v1/sync` or `POST /api/v1/sync/upload`.
