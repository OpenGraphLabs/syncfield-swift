# Changelog

All notable changes to **syncfield-swift** are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.2] — 2026-05-13

Patch release that hardens `SyncFieldInsta360` for long Go 3S recordings. Public stream APIs remain source-compatible with 0.9.x.

### Changed
- **Insta360 stop now treats camera state as authoritative.** `stopCapture` callbacks may arrive without `videoInfo.uri` or time out while the camera has already stopped. The controller now accepts empty-URI ACKs, records an unresolved sidecar, and uses `getCurrentCaptureStatus` polling before cycling BLE.
- **Go 3S pairing now verifies the connected peripheral without rejecting docked cameras whose SDK metadata is delayed.** After BLE command readiness, the controller accepts definite ActionCam metadata (`go3Version` or Go 3 camera type), rejects definite box-only/other-model metadata, and provisionally accepts GO-family endpoints when all SDK host metadata is still nil so docked first-pair flows do not fail before a real command can run.
- **Pending sidecars now persist long-recording match metadata.** New optional fields capture start/stop wall-clock windows, camera duration, file size, and expected segment count while preserving decode compatibility with 0.9.1 sidecars.
- **Unresolved collect now prefers time-window matching.** New sidecars resolve camera media by filename timestamp inside the recorded wall-clock window, including multi-segment recordings. Legacy sidecars without the new fields keep the previous latest-video fallback.
- `SyncFieldVersion.current` bumped to `0.9.2`.

### Fixed
- Long recordings no longer fail user-visible stop solely because `stopCapture` omitted `videoInfo.uri`.
- Multiple unresolved sidecars on the same camera no longer silently resolve to the same newest mp4 when the new sidecar metadata is present.
- 18+ minute split recordings can download every matched segment as `<streamId>_segNN.mp4` before the pending sidecar is deleted.

## [0.9.1] — 2026-05-13

Patch release that hardens cross-host audio sync for ego + Insta360 wrist setups by guaranteeing the stop chirp is captured with usable post-chirp silence on every host. Source-compatible with 0.9.0; recompile and ship.

### Changed
- **`SessionOrchestrator.preStopTailMarginMs` default raised from 200 ms → 800 ms.** The orchestrator emits the stop chirp and then sleeps for `chirp.durationMs + preStopTailMarginMs` before broadcasting per-stream `stopRecording()`. The previous 200 ms tail was sized for an iPhone-only host, where the AVAssetWriter closes within milliseconds of the stop call. Insta360 wrist cameras stop the underlying mp4 noticeably earlier than the BLE `stopCapture` ACK round-trip (300–400 ms of trailing audio is dropped relative to the iPhone timeline in production captures), so the previous default left them with the chirp body landing inside the last few hundred ms of their recording and the downstream audio aligner's ±400 ms cross-correlation window with no usable post-chirp silence. The new 800 ms default covers the aligner window plus typical Insta360 stop slack with safety. Hosts that pass an explicit value continue to use exactly what they pass; only the implicit default changes.
- `SyncFieldVersion.current` bumped to `0.9.1`.

### Fixed
- **Insta360 wrist-cam stop chirps are now reliably captured end-to-end.** Production ego_wrist captures through 2026-05-12 lost the last 130–170 ms of the stop chirp body on each wrist camera, dropping audio-aligner confidence below the conservative threshold and (before the syncfield core's chirp-anchor fallback shipped) breaking video sync for the entire episode. Combined with the syncfield-side single-anchor fallback, this SDK change moves wrist-cam alignment confidence from the ~0.5–0.6 borderline range into the ~0.85+ comfortable range.

### Compatibility
- API-source-compatible with 0.9.x. Constructor signature unchanged; only the implicit default for `preStopTailMarginMs` shifts. Tests that pass `preStopTailMarginMs: 0` (e.g. `SessionOrchestratorChirpTests`) are unaffected.
- `stopRecording()` end-to-end latency increases by ~600 ms when the default tail margin is in effect. Hosts that pin the previous behaviour can pass `preStopTailMarginMs: 200` explicitly.

## [0.9.0] — 2026-05-12

This release pulls the wide-FOV egocentric capture configuration that was previously living in host apps (og-skill's `EgonautIPhoneCameraStream`) into the SDK, so `iPhoneCameraStream` now produces ultra-wide capture by default — matching the egocentric / head-mounted data-collection use case the SDK targets. Public API signatures are unchanged; existing call sites (`iPhoneCameraStream(streamId:)`, `iPhoneCameraStream(streamId:videoSettings:)`) compile and run identically, they just yield wider video.

### Changed (breaking)
- **`iPhoneCameraStream` now defaults to the back ultra-wide camera at minimum zoom.** Equivalent to the iOS Camera app's 0.5× lens. On devices with a physical `.builtInUltraWideCamera` (iPhone 11 and newer except SE), the stream selects it directly. On devices without one (iPhone SE, X, 8 and earlier) the stream falls back to `.builtInWideAngleCamera` via a `DiscoverySession` ranked by `videoFieldOfView` — preserving the pre-0.9 behaviour on that hardware. Devices with a multi-lens virtual camera get the widest physical sensor and the framing the user expects from a "0.5×" tap, rather than the default 1× crop. Existing call sites compile unchanged; recordings simply have a wider field of view.
- **Within the selected device, the format with the largest `videoFieldOfView` is picked at configuration time.** Multi-lens hardware can expose several formats at the same resolution with different effective FOV (some cropped for stabilization headroom); 0.9 picks the widest. Resolution / fps requested via `VideoSettings` is honoured as before — the FOV-max ranking only breaks ties among compatible formats.
- **Video stabilization is set to `.off` on the capture connection.** Standard / cinematic stabilization modes crop the sensor for motion headroom, silently narrowing the effective FOV and undoing the widest-format selection above. Capture pipelines that needed stabilization on must now set it themselves after `connect()` returns.
- **`videoZoomFactor` is locked to `minAvailableVideoZoomFactor` at both `configureSession` time and at the top of `startRecording`.** The re-application in `startRecording` is defensive: between session config and the first recorded frame, an intervening subsystem (preview manager, system camera UI) can nudge zoom off its floor, which on a multi-lens device snaps capture back to the standard 1× wide-angle framing. Recording-time re-enforcement guarantees the recorded clip starts at full ultra-wide framing every time.

### Added
- **`setIntrinsicMatrixHandler(_:)`** on `iPhoneCameraStream`. AVFoundation attaches the per-frame `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` to vended sample buffers when the connection supports it; the new handler delivers the extracted fx/fy/cx/cy plus sample-buffer dimensions in a `DeliveredCameraIntrinsics` struct. Runs on the capture serial queue. Hosts use this to write a `camera_intrinsics.json` sidecar without re-implementing the 3-way attachment lookup (`CMGetAttachment` → sample-attachments array → image-buffer attachment) that AVFoundation requires across iOS versions.
- **`activeCameraMetadata: ActiveCameraMetadata?`** on `iPhoneCameraStream`. Returns the device type, localized name, active-format dimensions, and `videoFieldOfView` after `connect()` resolves. Hosts use this to compute and write an FOV-based intrinsics estimate at recording start, before any frame with an attached matrix arrives.
- `SyncFieldVersion.current` bumped to `0.9.0`.

### Fixed
- **Powered-on Insta360 GO recording preflight is side-effect free again.** `refreshConnection` and `startRemoteRecording` no longer send a `getOptions` command probe before `startCapture`; they verify the BLE link, GO power flags, and SDK command object, then let the SDK's `startCapture` command be the first capture-channel operation. `getOptionsWithTypes` is reserved for real option reads such as WiFi credentials. Already-powered GO cameras are also no longer sent redundant wake advertisements during preflight/start, and the `startCapture` timeout is kept to an expected fast ACK window with a single reconnect retry.
- **Ambiguous `startCapture` cleanup no longer hammers the same stale command channel.** On a recoverable start failure, the controller marks the BLE session stale, reconnects through the existing identity/wake path, and then sends best-effort `stopCapture` cleanup. This avoids the observed `stopCapture` timeout followed by SDK `444` disconnect loop on powered-on cameras.

### Compatibility
- API-source-compatible. All public types and method signatures from 0.8 still compile.
- Runtime-behaviour-breaking on hardware with a `.builtInUltraWideCamera`: capture field of view widens, native pixel-buffer dimensions for that format may differ from the previous `.builtInWideAngleCamera` selection. Frame-processor consumers that hard-code dimensions (Vision models, custom feature extractors) should re-verify against the new format.
- No behaviour change on hardware without a `.builtInUltraWideCamera`. Those devices continue to receive `.builtInWideAngleCamera` capture via the discovery-session fallback.

## [0.8.0] — 2026-05-11

This release makes deferred Insta360 ingest a first-class SDK feature so host apps can record now and download wrist mp4s later (per-episode "Download" button, batched "Collect all" page) without re-implementing pairing, AP grouping, or sidecar bookkeeping themselves.

### Added
- **`SessionOrchestrator.remove(streamId:)` + `streamIds()`** for host-driven stream lifecycle. The orchestrator previously only exposed `add(_:)`, so host apps that pair Insta360 wrist cameras manually (per-role assignment driven by identify cue + `assignWristRole`) had no way to deregister a stream when the user unpaired or remapped. The app-side bookkeeping (`wristStreams[role]`) and the SDK-side `streams` array drifted, and the next `add(_:)` with the same `streamId` threw `duplicateStreamId` — breaking Remap, swap-roles (L↔R), and any retry after a partial pair. `remove(streamId:)` mirrors `add(_:)`: same `.idle | .connected` state guard, idempotent (returns `false` when the streamId is not registered), and rejects with `invalidTransition` during `.recording`/`.stopping`/`.ingesting`. The caller owns `stream.disconnect()`; the orchestrator only drops the registration. `streamIds()` returns the registered ids in insertion order so hosts can sweep their own state against the orchestrator's view (e.g. defensively remove any `cam_wrist_*` stream the SDK still tracks during a wipe-all remap).
- **3-2-1 countdown UX built into `SessionOrchestrator.startRecording`.** `startRecording(countdown:onTick:)` accepts an optional `CountdownSpec` and a per-tick callback. With `CountdownSpec.standard` the SDK plays ascending audible tones (880, 1047, 1175 Hz, 110 ms each) at 1-second intervals through the iPhone main speaker, then runs the atomic BLE start and the sync chirp. `onTick(remaining)` fires once per tick (3, 2, 1) so host UIs can flash the number on screen in lockstep. `CountdownSpec.silent` for visual-only countdown.
- **`SessionOrchestrator` manages `AVAudioSession` for chirp routing by default.** `connect()` applies `.playAndRecord` with mode `.videoRecording` and options `[.defaultToSpeaker, .mixWithOthers]`, then `overrideOutputAudioPort(.speaker)` to pin the route. BT routing is intentionally excluded so the chirp can't divert to BT earbuds during a recording. `AudioSessionPolicy.manualByHost` opts out.
- `SyncFieldAudioSession.applyManagedConfig()` public helper exposing the same config (idempotent) for hosts that want to apply it manually outside the orchestrator.
- **`SessionOrchestrator.finishRecording()`** closes a recording from `.stopping → .connected` without running per-stream `ingest`. The state machine previously had no path out of `.stopping` other than `ingest()`, forcing host apps that defer Insta360 downloads to call `disconnect()` from `.stopping` and absorb the throw. Use this whenever you intend to call `Insta360Collector` later instead of an immediate `ingest()`.
- **`Insta360Collector`** process-wide actor that performs deferred Insta360 wrist-camera downloads from a directory path, completely decoupled from any `SessionOrchestrator`. Entry points:
  - `Insta360Collector.shared.collectEpisode(_ episodeDir:progress:)` for one episode's `.pending.json` sidecars.
  - `Insta360Collector.shared.collectAll(root:progress:)` recursively finds every pending under `root`, groups by camera UUID, and joins each camera's AP **once** across all queued episodes. Matches og-skill's production batch-collect behaviour.

### Changed (breaking)
- `SessionOrchestrator.startRecording`'s `countdown` parameter changed type from `TimeInterval` to `CountdownSpec?`. Zero-arg callers continue to compile unchanged because the new default is `nil`. Callers passing a positive `TimeInterval` must migrate to a `CountdownSpec`.
- `Insta360CameraStream.ingest` and `Insta360Collector` no longer write `<streamId>.anchor.json` sidecars. The current SyncField sync core does not consume them; alignment uses `manifest.json` + `sync_point.json` + the iPhone's `*.timestamps.jsonl` + audio cross-correlation of the chirp across every mp4 audio track. The matching `Insta360PendingSidecar.writeAnchor` public helper has been removed.

### Fixed
- **Actor state-machine race in `SessionOrchestrator.startRecording` / `stopRecording` / `finishRecording`.** State transition was at the END of the method, after multiple `await` suspension points; a concurrent caller could pass the same `require()` check during those awaits and run the whole sequence twice (double chirp, double BLE startCapture/stopCapture causing `msg execute err` on the second send, corrupted AVAssetWriter finalize). State now transitions immediately after the require check, before any await, so reentrant calls fail fast with `invalidTransition`.
- **`Insta360BLEController.withTimeout` waited for the full timeout on every successful call.** `defer { group.cancelAll() }` ran at scope exit after the drain loop, so the drain awaited the timeout task's full `Task.sleep` to elapse naturally; every BLE command effectively took its `seconds` budget regardless of how fast the actual round-trip was. `cancelAll()` is now called explicitly before the drain so `Task.sleep` cancels immediately. This was the root cause of the 15 s `stopRecording` reported by host apps; it now returns in ~2 s.
- **Start chirp silently fell back to software-only emission on iOS 18 / A18 Pro under AVCaptureSession + active BLE peripheral.** Chirp player now uses pre-cached `AVAudioPlayer(contentsOf:)` plus belt-and-suspenders `AudioServicesPlaySystemSound`, calls `setActive(true) + overrideOutputAudioPort(.speaker)` before every play, and never re-applies `setCategory` (whose `'!pri'` failure under AVCaptureSession priority was transitioning the session through an interim state that silenced playback).

- `SyncFieldVersion.current` bumped to `0.8.0`.

### Compatibility
- Source-compatible at zero-arg call sites. Existing `session.startRecording()` and `session.ingest { ... }` continue to work unchanged. The new `.stopping → .connected` transition is purely additive in the state machine.

## [0.7.5] — 2026-05-11

### Added
- `Insta360WiFiDownloader.fetchResource` emits a per-file `[WiFiDownloader.throughput]` log line on completion with elapsed ms, byte count, and MB/s. Required first step for diagnosing slow Pod-docked transfers — without per-file timing it's impossible to attribute "the collect is slow" across the camera radio, the SDK's HTTP layer, and surrounding orchestration (apply hotspot, settle, socket setup).
- `SyncFieldVersion.current` bumped to `0.7.5`.

## [0.7.4] — 2026-05-11

### Fixed
- **`SyncFieldInsta360` recordings could lose camera identity if BLE dropped mid-session.** `Insta360CameraStream.stopRecording` read `connectedDeviceUUID` / `connectedDeviceName` off the live `Insta360BLEController` at write time, but Go-family BLE drops on RSSI dip / camera-side sleep clear `connectedDevice` in the disconnect delegate. The pending sidecar then got written with empty `bleUuid` / `bleName` and multiple wrist streams collided on the same `byUUID` bucket on the host's collect path — making the recording unroutable back to its source camera over WiFi. The controller now caches the last-known identity (`lastKnownDeviceUUID` / `lastKnownDeviceName`) at every successful pair/adopt and keeps it across disconnects; `stopRecording` falls through live → lastKnown → `boundUUID` for UUID, and live → lastKnown for name.
- **`SyncFieldInsta360` recordings could fail to stop if BLE dropped before stopCapture.** `startRemoteRecording`, `stopRemoteRecording`, and `wifiCredentials` threw `notPaired` immediately when `connectedDevice` was cleared, leaving the recording on the camera's SD card but unreachable through the documented stop/ingest flow. Each command now invokes a best-effort `reconnectIfNeeded` (targeted scan + connect using cached `lastKnownDeviceUUID`, 10 s + 10 s budget) before reading `commandManager()`. Recoverable disconnects are now transparent to the host; unrecoverable failures propagate the underlying scan/connect error so the existing caller error path is unchanged.
- `SyncFieldVersion.current` bumped to `0.7.4`.

## [0.7.3] — 2026-05-11

### Fixed
- `SyncFieldInsta360` remote Swift Package builds now use a conditional local `INSCameraServiceSDK` binary target when the Insta360 framework is discoverable, so host apps can depend on the released package without SwiftPM rejecting unsafe framework flags.
- `SyncFieldVersion.current` bumped to `0.7.3`.

## [0.7.2] — 2026-05-11

### Fixed
- `SyncFieldInsta360` package resolution now auto-detects the common `og-skill/mobile/ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework` layout even when Xcode checks the package out under DerivedData.
- `SyncFieldVersion.current` bumped to `0.7.2`.

## [0.7.1] — 2026-05-11

### Added
- `SyncFieldInsta360` now exposes `Insta360Scanner` for Go-family BLE discovery, UUID-based identify cues, explicit pair/unpair helpers, and UUID-bound `Insta360CameraStream(streamId:uuid:)` construction for multi-camera rigs.
- Added `DiscoveredInsta360`, `Insta360PendingSidecar`, `Insta360TranscodeOptions`, and focused `SyncFieldInsta360Tests` coverage for scanner predicates, timeout behavior, and pending sidecar persistence.

### Changed
- `Insta360BLEController` uses one process-wide `INSBluetoothManager`, maintains heartbeat while paired, retries scanner pair attempts, and rejects duplicate UUID bindings with `Insta360Error.uuidAlreadyBound`.
- `Package.swift` can use a local Insta360 SDK framework path during development so host apps can import `SyncFieldInsta360` from a sibling checkout without publishing a release first.
- `SyncFieldVersion.current` bumped to `0.7.1`.

## [0.6.1] — 2026-05-09

Production hardening for `SyncFieldInsta360`. The `#if canImport(INSCameraServiceSDK)` block was previously type-checked only when a host app linked the binary; this release ports the four fixes that the egonaut/og-skill production fork validated against real-world Go 3S usage (single and dual camera).

### Fixed
- **`SyncFieldInsta360` would not compile when the Insta360 SDK was linked.** `Insta360WiFiDownloader.download(...)` and `fetchResource(...)` declared `progress` as non-escaping but passed it into the SDK's escaping completion handler. Both now take `@escaping @Sendable (Double) -> Void`. `Insta360CameraStream.ingest(...)` bridges the protocol's non-escaping `progress` with `withoutActuallyEscaping` — no protocol change required.
- **iPhone got stuck on the camera AP after `ingest()`.** The previous `defer` cleanup ran `removeConfiguration` but couldn't `await`, so iOS had no time to disassociate from the camera SSID and rejoin a saved Wi-Fi. `defer` is now an explicit cleanup block that awaits a short reachability poll (`waitForSystemWiFiRestore`) before returning.
- **`waitForReachability` budget too tight (3 attempts).** The camera AP's DHCP-assigned IP appears 1–5 s after `apply` resolves; bumped to 8 attempts. Eliminates the intermittent `cameraNotReachable` flake on slower iOS Wi-Fi state transitions.
- **`applyHotspot` could hang forever.** `NEHotspotConfigurationManager.apply` has no built-in deadline; if iOS' Wi-Fi state machine deadlocks (most common on a back-to-back camera-A→camera-B switch in a multi-camera batch), the completion handler never fires. `applyHotspot` now wraps each attempt in a 30 s timeout and retries once after a settle window — covers the transient `internal` / `system` errors iOS surfaces while it's still releasing the previous hotspot config.
- **Two `Insta360CameraStream` instances could pair to the same camera.** `Insta360BLEController.pair()` now consults a process-wide registry of already-paired UUIDs and skips them during scan. Public API unchanged. Multi-camera (e.g. ego + wrist) now works by simply adding multiple `Insta360CameraStream` instances to one `SessionOrchestrator`.

### Changed
- `SyncFieldVersion.current` bumped to `0.6.1`. (Version string was unintentionally left at `0.5.0` in 0.6.0; this release also corrects that.)
- README's `Info.plist` table now lists `NSLocalNetworkUsageDescription` for `Insta360CameraStream`. Required on iOS 14+ for the camera HTTP server (192.168.42.1) and was already documented in `docs/insta360.md`.

### Compatibility
- Source-compatible. No public API changes; existing call sites that worked with 0.6.0 continue to compile. The `progress` parameter type changed from non-escaping to `@escaping` on two `Insta360WiFiDownloader` methods, but `@escaping` is purely additive at call sites.
- Output format unchanged.

## [0.6.0] — 2026-05-05

### Added
- `iPhoneRawIMUStream` — direct accelerometer / gyroscope / magnetometer streams at the device's native sampling rate, complementing the fused `iPhoneMotionStream`.

### Known issue (fixed in 0.6.1)
- `SyncFieldInsta360` does not compile when `INSCameraServiceSDK.xcframework` is linked into the host target. Upgrade to 0.6.1.

## [0.5.0] — 2026-04-29

JSONL field names now match the SyncField server schema. The previous `frame` / `timestamp_ns` keys produced by both writers caused `Sensor load failed for imu: 'capture_ns'` server-side, dropping the IMU stream and tripping the "fewer than 2 streams" guard for any single-camera-plus-IMU recording.

### Changed
- **BREAKING:** `SensorWriter` (`imu.jsonl` and other `*.jsonl` sensor streams) now emits `frame_number` and `capture_ns` instead of `frame` and `timestamp_ns`. `channels` and the optional `device_timestamp_ns` are unchanged.
- **BREAKING:** `StreamWriter` (`*.timestamps.jsonl` per-frame video timestamp sidecars) now emits `frame_number` and `capture_ns` instead of `frame` and `timestamp_ns`. `uncertainty_ns` is unchanged.
- `SyncFieldVersion.current` bumped to `0.5.0`.

### Migration
- Recordings produced by 0.4.x or earlier are NOT readable by the SyncField server's strict loaders without a key rename. New recordings produced by 0.5.0 work end-to-end with `syncfield-app` (Python server) `load_sensor_jsonl` and `FrameTimestamp.from_dict`.

## [0.4.0] — 2026-04-28

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
