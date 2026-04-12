# syncfield-swift v0.2 — Plan D: egonaut iOS app migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Migrate the egonaut iOS mobile app from the v0.1 "timestamping bridge" SDK surface to the v0.2 recording-orchestrator SDK. **Breaking change** — no compatibility shim. Result: ~1500 LOC of native Swift + two RN dependency packages (`react-native-vision-camera`, `react-native-sensors`) removed; a ~100-LOC thin RN bridge over `SessionOrchestrator` remains.

**Working directory:** `/Users/jerry/Documents/egonaut/mobile/ios/` (the egonaut repo, NOT syncfield-swift).

**Prerequisites:**
- syncfield-swift v0.2.3 (Plans A + A.1 + B + C) released and reachable via Swift Package Manager (`git` tag or Podspec)
- Insta360 xcframework distribution strategy resolved (Plan C, Option A or B)

---

## Phase D-0: Dependency swap

### Task 0.1: Point egonaut at new syncfield-swift

**Files:**
- Modify: `EgonautMobile.xcodeproj/project.pbxproj` (via Xcode GUI or xcodeproj CLI) — bump the SyncField SPM dependency to the v0.2.x tag
- Modify: `EgonautMobile.xcodeproj` — also add `SyncFieldUIKit` and `SyncFieldInsta360` library product dependencies

- [ ] **Step 1: Open `EgonautMobile.xcworkspace` in Xcode**

- [ ] **Step 2: File → Add Package Dependencies → bump SyncField to `v0.2.3-plan-c`** (or `main` branch of `breaking/sdk-expansion`)

- [ ] **Step 3: Add `SyncFieldUIKit` + `SyncFieldInsta360` library products** to `EgonautMobile` target

- [ ] **Step 4: Verify project builds**

```bash
xcodebuild -workspace EgonautMobile.xcworkspace -scheme EgonautMobile \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: **fails** — existing egonaut code uses the v0.1 SDK surface (`SyncSession.stamp(...)` etc.) which no longer exists. The subsequent phases fix each callsite.

- [ ] **Step 5: Commit**

```bash
git add EgonautMobile.xcodeproj/project.pbxproj Podfile.lock
git commit -m "chore: bump syncfield-swift to v0.2.3"
```

---

## Phase D-1: Delete v0.1-era native modules

### Task 1.1: Remove obsolete Swift files

**Files to delete:**
- `EgonautMobile/SyncField/SyncFieldManager.swift` → replaced by direct `SessionOrchestrator` in the bridge
- `EgonautMobile/Tactile/TactileGloveManager.swift` → replaced by `TactileStream`
- `EgonautMobile/Tactile/TactileBridgeModule.swift` → replaced by simplified bridge in D-3
- `EgonautMobile/Tactile/TactileConstants.swift` → now in SDK
- `EgonautMobile/Insta360/Insta360CameraManager.swift` → replaced by `Insta360CameraStream`
- `EgonautMobile/Insta360/Insta360WiFiTransferManager.swift` → replaced by SDK
- `EgonautMobile/Insta360/Insta360WiFiTransferBridge.swift` → replaced by SDK
- `EgonautMobile/Insta360/Insta360BridgeModule.swift` → replaced by simplified bridge in D-3
- `EgonautMobile/Insta360/DeviceBridgeProtocol.swift` → unused after SDK migration
- `EgonautMobile/HandDetectionFrameProcessor.swift` → replaced with SDK `setFrameProcessor` hook in D-2

- [ ] **Step 1: Delete each file via `git rm`**

- [ ] **Step 2: Commit (project will not build yet — expected)**

```bash
git rm EgonautMobile/SyncField/SyncFieldManager.swift \
       EgonautMobile/Tactile/TactileGloveManager.swift \
       EgonautMobile/Tactile/TactileBridgeModule.swift \
       EgonautMobile/Tactile/TactileConstants.swift \
       EgonautMobile/Insta360/Insta360CameraManager.swift \
       EgonautMobile/Insta360/Insta360WiFiTransferManager.swift \
       EgonautMobile/Insta360/Insta360WiFiTransferBridge.swift \
       EgonautMobile/Insta360/Insta360BridgeModule.swift \
       EgonautMobile/Insta360/DeviceBridgeProtocol.swift \
       EgonautMobile/HandDetectionFrameProcessor.swift
git commit -m "remove: v0.1-era native device managers, superseded by SDK adapters"
```

---

## Phase D-2: Rewrite `SyncFieldBridgeModule`

### Task 2.1: Replace the Promise-based stamp/record bridge with SessionOrchestrator-based lifecycle bridge

**Files:**
- Modify (full rewrite): `EgonautMobile/SyncField/SyncFieldBridgeModule.swift`

The new surface JS calls:
- `connect(hostId: String, outputDir: String)` — creates `SessionOrchestrator`, adds streams, calls `connect()`
- `startRecording()` — returns `SyncPoint` dict (JS can inspect `monotonic_ns`, chirp data)
- `stopRecording()` — returns stop report
- `ingest()` — returns ingest report (progress surfaced via `onProgress` event)
- `disconnect()` — tears down
- `setHandDetection(enabled: Bool)` — attaches/detaches a CoreML hand-detection frame processor on the iPhone camera stream

Event emitter:
- `healthEvent` — emits each `HealthEvent` as JS payload
- `ingestProgress` — emits `{streamId, fraction}` during ingest

- [ ] **Step 1: Implement new `SyncFieldBridgeModule.swift`** — ~150 lines. Should use `SessionOrchestrator` directly, subscribe to `healthEvents` for pushing JS events, and own an `iPhoneCameraStream` + `iPhoneMotionStream` + optional `TactileStream`×2 + optional `Insta360CameraStream` depending on which device configuration JS specifies at `connect()`.

- [ ] **Step 2: Add hand-detection frame processor registration**

The existing `HandDetectionFrameProcessor.swift` contained the Vision/CoreML logic. Port the detection code (not the VisionCamera plugin framing) into a helper inside the bridge module or a sibling file. Register it via `cameraStream.setFrameProcessor(throttleHz: 10) { buffer, _ in ... }`.

- [ ] **Step 3: Commit**

```bash
git add EgonautMobile/SyncField/SyncFieldBridgeModule.swift
git commit -m "feat: rewrite SyncFieldBridgeModule as thin wrapper over SessionOrchestrator"
```

---

## Phase D-3: Remove JS-side old APIs, add new bridge event handlers

### Task 3.1: JavaScript (React Native) side

**Files (approximate paths — verify in the egonaut JS tree):**
- Modify: the JS module that called `SyncField.start()`, `SyncField.stamp()`, `SyncField.record()` — replace with `SyncField.connect()`, `SyncField.startRecording()`, etc.
- Remove: `react-native-vision-camera` usage (camera preview now via native `SyncFieldPreviewView` exposed as an RN Native Component — see D-4)
- Remove: `react-native-sensors` usage (IMU now captured natively via `iPhoneMotionStream`)
- Add: event listeners for `healthEvent` and `ingestProgress`

- [ ] **Step 1: Identify every JS file that imports from the SyncField bridge** (usually `NativeModules.SyncFieldBridgeModule` or similar) — use grep in the RN tree.

- [ ] **Step 2: Rewrite callsites** to the new lifecycle. The API surface shrinks substantially — no more per-frame calls from JS.

- [ ] **Step 3: Remove the two now-unused RN packages**

```bash
cd mobile     # egonaut's RN root
yarn remove react-native-vision-camera react-native-sensors
cd ios
pod install
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(js): adopt new SyncField bridge API, drop vision-camera and sensors deps"
```

---

## Phase D-4: Native preview component

### Task 4.1: RN Native Component wrapping `SyncFieldPreviewView`

**Files:**
- Create: `EgonautMobile/SyncField/SyncFieldPreviewViewManager.swift` — minimal RCTViewManager that exposes `SyncFieldPreviewView` to JS
- Create: a tiny JS wrapper component in the RN tree

- [ ] **Step 1: Implement view manager (~30 lines of RN boilerplate)**

- [ ] **Step 2: JS wrapper**

- [ ] **Step 3: Verify preview renders in the app**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: RN Native Component wrapping SyncFieldPreviewView"
```

---

## Phase D-5: Smoke test on device + clean up

### Task 5.1: Device test for each of the three use cases

- [ ] **Step 1: egocentric-only** — deploy to physical iPhone, start a recording, verify an episode directory with `cam_ego.mp4` + audio track + `imu.jsonl` + `sync_point.json` (with chirp_start/stop) is produced.

- [ ] **Step 2: ego + tactile** — pair left + right Oglo gloves, record, verify `tactile_left.jsonl` and `tactile_right.jsonl` contain 100 Hz samples with both `timestamp_ns` and `device_timestamp_ns`.

- [ ] **Step 3: ego + wrist** — pair Insta360 Go 3S, record, verify the BLE-trigger → WiFi-download flow completes during `ingest()`, with `cam_wrist.mp4` landing in the episode directory alongside `cam_wrist.anchor.json`.

- [ ] **Step 4: Confirm audio chirps are visible in `cam_ego.mp4`'s audio track** — use QuickTime or ffmpeg to view the waveform; the 500-ms linear-FM sweep should be clearly visible at start and end.

- [ ] **Step 5: Post-recording** — upload an episode to the syncfield server and confirm it processes without errors (validates the file format contract end-to-end).

- [ ] **Step 6: Final commit and tag**

```bash
git commit -m "test: device smoke test passes for all three use cases"
# tag in the egonaut repo to mark the migration complete
git tag egonaut-syncfield-v0.2-migration
```

---

## Rollout plan

1. Land Plan D commits on a dedicated `syncfield/v0.2-migration` branch in egonaut
2. Open a PR, run full CI
3. Device smoke tests by the egonaut team (Phase D-5)
4. Merge to egonaut main when green
5. Tag syncfield-swift `v0.2.3` as the version egonaut pins to
6. Future syncfield-swift work (multi-host, chirp-based cross-host alignment, etc.) lands behind feature-flagged new targets — egonaut stays on v0.2.x until explicitly upgraded

---

## Net change count (estimate)

- egonaut native Swift: **-1500 LOC** (delete), **+200 LOC** (new bridge + preview view manager) = net **-1300 LOC**
- egonaut JS: **-400 LOC** (vision-camera/sensors call-sites), **+100 LOC** (new lifecycle hooks) = net **-300 LOC**
- RN dependencies: **-2 packages** (`react-native-vision-camera`, `react-native-sensors`)
- New SDK-side: 0 (all work already in syncfield-swift repo)

---

## Execution handoff

Execute with superpowers:subagent-driven-development after Plans A + A.1 + B + C are all green in syncfield-swift. This plan is cross-repo; execution subagents should be dispatched with explicit `/Users/jerry/Documents/egonaut/mobile/ios` as the working directory.
