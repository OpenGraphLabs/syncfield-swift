# Changelog

All notable changes to **syncfield-swift** are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0-rc1] — 2026-04-28

First-class hand FOV quality monitoring for egocentric recordings.

### Added
- `HandQualityMonitor` actor (`Sources/SyncField/Quality/`): per-hand IN / NEAR_EDGE / OUT_OF_FRAME state machine with chirality-first assignment + spatial-continuity fallback, eager near-edge entry, debounced OOF/recovery, and a configurable startup grace window.
- `EventWriter` actor (`Sources/SyncField/Writers/`): append-only JSON Lines writer for per-episode interval and point events. Each line is independently parseable; open intervals at finalize are auto-closed with `payload._truncated_at_stop = true`.
- `SessionOrchestrator` public API:
  - `init(... handQualityConfig: HandQualityConfig = .default)` — opt-out via `enabled: false`.
  - `setHandQualityConfig(_:)` — applies on the next `startRecording()`.
  - `handQualityEvents() -> AsyncStream<HandQualityEvent>` — live state transitions for UI / audio cue consumers.
  - `ingestHandObservations(_:frame:monotonicNs:)` — host apps that already run Vision hand-pose detection feed observations through this method.
  - `logEvent(kind:monotonicNs:endMonotonicNs:payload:)` — generic interval-or-point domain event logger writing through the same `events.jsonl`.
- `HandQualitySummary` — `hand_quality.json` schema with `verdict` (good / marginal / reject), `overall_score`, `sub_scores`, `raw` (snake-case `QualityStats`), `thresholds`, and `config`. Mirrors the existing `egomotion_quality.json` shape.
- `WriterFactory.makeEventWriter(streamId:)` — `events.jsonl` factory rooted at the episode directory.
- `VisionHandConversion` — `HandObservation.from(vision:minConfidence:)` extension behind a `canImport(Vision)` guard for host apps that want to convert `VNHumanHandPoseObservation` directly.

### Changed
- `SyncFieldVersion.current` bumped to `0.4.0-rc1`.

### Compatibility
- Additive only. Existing 0.3.x consumers compile unchanged. Recordings now also produce `events.jsonl` and `hand_quality.json` in the episode directory; consumers that enumerate files should ignore unknown extensions (already the standard pattern).

---

## [0.3.0] — 2026-04-26

First release positioned for external customer adoption. No breaking source changes vs. `0.2.11`; the bump reflects packaging, documentation, and privacy work that brings the SDK to production quality.

### Added
- `PrivacyInfo.xcprivacy` manifest in both `SyncField` and `SyncFieldInsta360` targets, declaring the required-reasons APIs the SDK uses (`SystemBootTime`, `FileTimestamp`, `DiskSpace`). Apps embedding the SDK now inherit a valid privacy manifest automatically and pass App Store privacy review without further work.
- `docs/integration.md` — full lifecycle, health-event subscription, audio-chirp configuration, atomic-start rollback semantics, and host-app patterns surfaced from production usage in egonaut.
- `docs/insta360.md` — explicit guidance on the optional `SyncFieldInsta360` module: how to obtain `INSCameraServiceSDK.xcframework` from Insta360, how to embed it in a host app target alongside SPM, required Info.plist keys and capabilities, and the BLE/Wi-Fi ingest flow.

### Changed
- **README rewritten** against the actual public API. Earlier README revisions documented a `SyncSession` / `stamp()` / `record()` / `link()` API that never shipped; the orchestrator-and-streams design that has been the real public surface since `0.2.0` is now correctly reflected. If you copied code from the prior README, replace it with the patterns shown in `examples/` or in the new README quick-start.
- `SyncFieldVersion.current` is now the single source of truth for the SDK version. `SyncFieldInsta360.version` re-exports it, so the optional module cannot drift from the core release. Bumped from `"0.2.0"` to `"0.3.0"`.
- README install snippet now reads `from: "0.3.0"`.

### Compatibility

No source-level breaking changes. Existing call sites built against `0.2.x` continue to compile and run unchanged. The only customer-visible value change is `sync_point.json` / `manifest.json` writing `"sdk_version": "0.3.0"` instead of `"0.2.0"` — downstream sync-server consumers that pin on the version string should update accordingly.

---

## [0.2.11] — 2026-04-13

### Added
- `VideoSettings.fps` — target frame rate on `iPhoneCameraStream`. Falls back gracefully if the device cannot meet the requested rate at the chosen resolution.
- Default chirp now sweeps **17–19 kHz** (near-ultrasonic) so the alignment marker is inaudible to most users while still being recoverable from the audio track.

### Fixed
- AVAudioEngine warmup + pre-flight before `scheduleBuffer`, eliminating an `NSException` seen on first chirp after cold start.

## [0.2.10] — earlier

### Added
- `VideoSettings` struct with built-in presets (`.hd720`, `.hd720_60`, `.fullHD`, `.uhd4K`).
- `iPhoneCameraStream` configurable resolution, codec (H.264 / HEVC), and bitrate.

## [0.2.9 → 0.2.4] — earlier

### Added
- `SessionOrchestrator.stopRecording` writes `manifest.json` (in addition to writing it again at `ingest()`), so hosts that defer or skip `ingest()` still produce a complete episode catalogue.
- `SessionOrchestrator` parallelises per-stream stop fan-out — back-to-back BLE stop commands on multiple Insta360 cameras no longer fail.
- `SessionOrchestrator.add(_:)` permitted in `.connected` state for streams the host has prepared and connected externally (deferred-connect pattern).
- `TactileStream.setSampleHandler` for live preview / gesture recognition independent of file recording.

### Fixed
- `iPhoneCameraStream`: serialised every recording-state mutation onto the video queue, eliminating the `AVAssetWriter` "status is 0" race.
- Chirp emission gated on `isHostTimeValid` to prevent an `NSException` when the audio host clock had not yet stabilised.

## [0.2.3] — Insta360 module

### Added
- `SyncFieldInsta360` SPM target — optional Insta360 Go 3S adapter.
- `Insta360CameraStream`: BLE pair → start-capture → stop-capture → Wi-Fi auto-switch → mp4 download → BLE-ACK anchor sidecar.
- `Insta360BLEController` and `Insta360WiFiDownloader` — internal building blocks gated on `canImport(INSCameraServiceSDK)`.

## [0.2.2] — Tactile module

### Added
- `TactileStream`, `TactileBLEClient`, `TactilePacketParser` — Oglo glove BLE adapter with firmware-side hardware timestamps and 100 Hz packet decoding.

## [0.2.1] — Audio chirp

### Added
- `ChirpSpec`, `ChirpEmission`, `ChirpSource`, `ChirpPlayer` protocol, `AVAudioEngineChirpPlayer`, `ChirpSynthesis.render` (linear FM sweep with cosine envelope).
- `SessionOrchestrator` emits chirps at start and stop and persists their host-monotonic ns to `sync_point.json`.
- `iPhoneCameraStream` records the microphone alongside video so the chirp is captured into the session.

## [0.2.0] — Core orchestrator

### Added
- `SessionOrchestrator` state machine (idle → connected → recording → stopping → ingesting → connected) with atomic start and rollback.
- `SyncFieldStream` protocol, `StreamConnectContext`, `StreamStopReport`, `StreamIngestReport`.
- `iPhoneCameraStream` (AVFoundation capture + AVAssetWriter), `iPhoneMotionStream` (CoreMotion device motion).
- `SyncFieldUIKit` with `SyncFieldPreviewView` (UIKit) and `SyncFieldPreview` (SwiftUI).
- `HealthBus` / `HealthEvent` async fan-out.
- `WriterFactory`, `StreamWriter`, `SensorWriter`, `ManifestWriter`, `SessionLogWriter`.

## [0.1.0] — Initial scaffolding

Initial Swift Package Manager scaffold. The README at this revision documented an aspirational `SyncSession` / `stamp()` / `record()` API that was superseded by the orchestrator design before any release.
