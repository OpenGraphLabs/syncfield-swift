# Integration guide

This document covers the host-app patterns that go beyond the README's quick-start: state-machine details, health events, the audio-chirp markers, error handling, and the patterns we have observed in production hosts (egonaut).

If you're integrating for the first time, read this top-to-bottom once. After that, the example view controllers in [`examples/`](../examples) are usually the fastest reference.

## Table of contents

1. [Lifecycle in detail](#lifecycle-in-detail)
2. [Health events](#health-events)
3. [Audio chirps](#audio-chirps)
4. [Error handling and rollback](#error-handling-and-rollback)
5. [Common host patterns](#common-host-patterns)
6. [Threading model](#threading-model)
7. [Putting it together](#putting-it-together)

## Lifecycle in detail

`SessionOrchestrator` is an `actor` with a strict state machine:

```
              add(_:)
              ┌─────┐
              ▼     │
    ┌────────────────────────┐
    │         idle           │◀────────────────┐
    └────────────────────────┘                 │
              │                                │
              │ connect()                      │ disconnect()
              ▼                                │
    ┌────────────────────────┐                 │
    │       connected        │─────────────────┘
    └────────────────────────┘
              │           ▲
              │           │
              │ start     │ ingest()
              │ Recording()│ (returns control to .connected)
              ▼           │
    ┌────────────────────────┐
    │       recording        │
    └────────────────────────┘
              │
              │ stopRecording()
              ▼
    ┌────────────────────────┐
    │       stopping         │
    └────────────────────────┘
              │
              │ ingest()
              ▼
    ┌────────────────────────┐
    │       ingesting        │
    └────────────────────────┘
              │
              │ (auto)
              ▼
        connected ──────────────────────┐
                                        │
                                disconnect() → idle
```

Allowed transitions:

| From | Method | To |
|---|---|---|
| `idle` | `add(_:)` | `idle` |
| `idle` | `connect()` | `connected` |
| `connected` | `add(_:)` | `connected` *(see below)* |
| `connected` | `startRecording()` | `recording` |
| `connected` | `disconnect()` | `idle` |
| `recording` | `stopRecording()` | `stopping` |
| `stopping` | `ingest()` | `connected` (via `ingesting`) |

Any other call throws `SessionError.invalidTransition`.

### Adding streams in `.connected`

`add(_:)` is allowed in `.connected` for streams that the host app has prepared independently — e.g. a wrist camera paired through a separate UI flow before the user starts recording. Streams added post-connect do **not** receive `connect(context:)` from the orchestrator; the host is responsible for preparing them.

## Health events

Subscribe to lifecycle and error notifications via an `AsyncStream<HealthEvent>`:

```swift
let session = SessionOrchestrator(hostId: "iphone_ego", outputDirectory: dir)

Task {
    for await event in await session.healthEvents {
        switch event {
        case .streamConnected(let id):
            print("[\(id)] connected")
        case .streamDisconnected(let id, let reason):
            print("[\(id)] disconnected: \(reason)")
        case .samplesDropped(let id, let count):
            print("[\(id)] dropped \(count) samples")
        case .ingestProgress(let id, let fraction):
            print("[\(id)] \(Int(fraction * 100))%")
        case .ingestFailed(let id, let error):
            print("[\(id)] INGEST FAILED: \(error)")
        }
    }
}
```

The stream is finalised when the session reaches `.idle` after `disconnect()`, so the `for await` loop terminates naturally.

## Audio chirps

`SessionOrchestrator` plays a short tone burst at start and stop by default. The chirp is recorded into the iPhone's audio track and used by the SyncField sync server as a fallback alignment marker when timestamp clocks across hosts have drifted (or when comparing to GoPro / external recorders that lack a host clock).

### Tuning the chirp

```swift
let session = SessionOrchestrator(
    hostId: "iphone_ego",
    outputDirectory: dir,
    startChirp: .defaultStart,            // 17–19 kHz sweep, 200 ms
    stopChirp:  .defaultStop,
    postStartStabilizationMs: 200,        // wait for AVAudioEngine to settle
    preStopTailMarginMs: 200)             // capture full chirp tail
```

### Disabling the chirp

Pass `nil` for either spec to suppress that side. Disabling stop-chirp loses cross-host fallback alignment; disabling start-chirp also loses it but is sometimes desirable when the host app already provides its own UX feedback at start.

```swift
let session = SessionOrchestrator(
    hostId: "iphone_ego",
    outputDirectory: dir,
    startChirp: nil,
    stopChirp: nil)
```

The `sync_point.json` then omits `chirp_start_ns` / `chirp_stop_ns` and the sync server falls back purely to host-monotonic alignment.

### Custom player

If you need to drive the chirp through an existing `AVAudioEngine` (e.g. you already mix other audio into the recording), implement `ChirpPlayer` and pass it in:

```swift
let player: ChirpPlayer = MyAudioBridge()
let session = SessionOrchestrator(
    hostId: "iphone_ego",
    outputDirectory: dir,
    chirpPlayer: player)
```

`ChirpPlayer.play(_ spec:)` returns a `ChirpEmission` containing the host-monotonic ns at which the first audio sample of the chirp left the device — that nanosecond is what gets persisted to `sync_point.json`.

## Error handling and rollback

`startRecording()` is **atomic across all registered streams**: every stream's `startRecording(clock:writerFactory:)` is invoked concurrently inside a `TaskGroup`. If any stream throws, the orchestrator stops every stream that did succeed, deletes the partially-written episode directory, and returns to `.connected`.

The thrown error is `SessionError.startFailed(cause:rolledBack:)` carrying the original cause and the list of stream IDs that needed to be rolled back.

```swift
do {
    try await session.startRecording()
} catch SessionError.startFailed(let cause, let rolledBack) {
    // cause is the underlying error from the failing stream
    // rolledBack is the list of streams whose startRecording succeeded and were stopped
    presentRetry(reason: cause, retryable: rolledBack)
}
```

`stopRecording()` is more permissive. Each stream's `stopRecording()` runs concurrently and **errors are collected, not short-circuited** — a failure in one stream's BLE stop command does not prevent another stream's `AVAssetWriter.finishWriting` from completing. The first error encountered is rethrown after every stream has finished (or failed).

This matters in practice: a misbehaving Insta360 camera will not corrupt the iPhone-side mp4.

## Common host patterns

These patterns come from production usage in egonaut.

### Skipping `ingest()`

Some host apps want to defer the ingest phase — typically to upload before doing the (sometimes minutes-long) Wi-Fi switch + Insta360 download. The orchestrator now writes `manifest.json` at the end of `stopRecording()` as well as at the end of `ingest()`, so a host that does

```swift
_ = try await session.stopRecording()
// skip ingest()
try await session.disconnect()
```

still ends up with a complete episode directory minus the Insta360 mp4. Note that `disconnect()` requires the session to be in `.connected`, so the orchestrator transitions internally; if you skip `ingest()` you need to handle the resulting state explicitly:

```swift
do {
    _ = try await session.stopRecording()                  // -> .stopping
    try await session.disconnect()                         // throws: .stopping → .idle is not allowed
} catch SessionError.invalidTransition {
    // Force the session through .ingesting → .connected to drain
    _ = try? await session.ingest { _ in /* no-op */ }
    try await session.disconnect()
}
```

A clean alternative that stays inside the supported transitions:

```swift
_ = try await session.stopRecording()
_ = try await session.ingest { _ in }     // returns immediately for native streams
try await session.disconnect()
```

For native streams (`iPhoneCameraStream`, `iPhoneMotionStream`, `TactileStream`) `ingest()` is a no-op anyway, so always calling it is the safest pattern.

### Deferred-connect for late-attached streams

When a wrist camera is paired through a separate UI flow that may finish *after* the user is ready to start, register it after `connect()`:

```swift
try await session.add(cam)
try await session.add(imu)
try await session.connect()                   // opens iPhone hardware

// ... later, when the user has paired the wrist camera ...
let wrist = Insta360CameraStream(streamId: "cam_wrist")
try await wrist.prepare()
try await wrist.connect(context: /* host-built context */)  // host pairs externally
try await session.add(wrist)                                 // already prepared & connected
try await session.startRecording()                           // includes wrist
```

The orchestrator does not call `connect(context:)` for streams added in `.connected` — the host is responsible for ensuring the stream is ready.

### Ignoring per-stream ingest failures

`session.ingest { progress in ... }` returns `IngestReport` whose `streamResults: [String: Result<...>]` lets you inspect each stream individually. A common pattern is to log Insta360 download failures but proceed with the iPhone-only episode:

```swift
let report = try await session.ingest { _ in }
for (id, result) in report.streamResults {
    if case .failure(let err) = result {
        log.warning("ingest failed for \(id): \(err) — proceeding without this stream")
    }
}
```

## Threading model

- `SessionOrchestrator` is an `actor`. Calls from multiple tasks are serialised automatically.
- Each stream owns its own internal queue:
  - `iPhoneCameraStream` — `syncfield.camera` `userInitiated`
  - `iPhoneMotionStream` — `syncfield.motion` `userInitiated`
  - `TactileStream` — BLE delivery queue
- `TactileStream.setSampleHandler` fires on the BLE delivery queue. Dispatch to the main queue yourself if the handler updates UI:

```swift
left.setSampleHandler { event in
    DispatchQueue.main.async { self.updatePreview(event) }
}
```

- `HealthEvent` is delivered via `AsyncStream` and can be consumed from any task.

## Putting it together

A minimal, production-shaped integration:

```swift
import SyncField
import SyncFieldUIKit

final class CaptureCoordinator {
    private let cam = iPhoneCameraStream(streamId: "cam_ego",
                                         videoSettings: .hd720_60)
    private let imu = iPhoneMotionStream(streamId: "imu", rateHz: 100)

    private let session: SessionOrchestrator
    private var healthTask: Task<Void, Never>?

    init(outputDirectory: URL) {
        session = SessionOrchestrator(
            hostId: UIDevice.current.identifierForVendor?.uuidString ?? "iphone",
            outputDirectory: outputDirectory)
    }

    func prepare() async throws {
        try await session.add(cam)
        try await session.add(imu)

        healthTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.session.healthEvents {
                self.handle(event)
            }
        }

        try await session.connect()
    }

    func startRecording() async throws { try await session.startRecording() }

    func finishRecording() async throws -> URL {
        _ = try await session.stopRecording()
        let report = try await session.ingest { _ in }
        for (id, result) in report.streamResults {
            if case .failure(let err) = result {
                NSLog("ingest \(id): \(err)")
            }
        }
        try await session.disconnect()
        healthTask?.cancel()
        return await session.episodeDirectory
    }

    private func handle(_ event: HealthEvent) {
        // Surface to UI / logs / analytics
    }

    var preview: UIView { SyncFieldPreviewView(stream: cam) }
}
```

That's the full integration surface. Beyond this, customisations live inside the streams you add — not the orchestrator.
