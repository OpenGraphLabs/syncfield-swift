# `SyncFieldInsta360` — optional Insta360 Go 3S module

`SyncFieldInsta360` lets you trigger and download from an Insta360 Go 3S as a regular `SyncFieldStream`, time-aligned with the iPhone camera and other sensors registered on the same `SessionOrchestrator`.

It is **opt-in** because it depends on `INSCameraServiceSDK.xcframework`, a closed-source binary distributed by Insta360 directly to approved partners. We cannot redistribute it. If the framework is not linked into your host app, every method on `Insta360CameraStream` throws `Insta360Error.frameworkNotLinked` and the rest of SyncField runs unchanged.

## When you need this module

You only need `SyncFieldInsta360` if a recording rig pairs an iPhone with one or more Insta360 Go 3S cameras (typical: wrist-mounted wrist camera alongside the egocentric iPhone). For iPhone-only or iPhone + tactile glove rigs, ignore this document — the core `SyncField` product is enough.

## Obtaining `INSCameraServiceSDK.xcframework`

1. Apply to the Insta360 Developer Program at [insta360.com/developer](https://www.insta360.com/developer) and request access to the iOS Camera SDK for the Go 3S.
2. Insta360 reviews requests manually. Approval typically takes a few business days and requires a description of your use case.
3. Once approved, you receive `INSCameraServiceSDK.xcframework` plus the SDK licence agreement. **Do not check the binary into a public repository** — your licence almost certainly forbids redistribution.

If you already work with Insta360 commercially, ask your account manager for the Go 3S iOS SDK directly.

## Linking the framework into your host app

`SyncFieldInsta360` itself is shipped as a Swift package target. The Insta360 binary lives in your host app, **not** in this repo.

1. Drop `INSCameraServiceSDK.xcframework` somewhere under your app's source tree (e.g. `Vendor/INSCameraServiceSDK.xcframework`).
2. In Xcode, open your **app target** ▸ **General** ▸ **Frameworks, Libraries, and Embedded Content** and drag the xcframework in. Set **Embed & Sign**.
3. The xcframework brings in CoreBluetooth, NetworkExtension, and SystemConfiguration transitively — Xcode auto-resolves them.
4. Add the `Hotspot Configuration` capability to the app target — required for `NEHotspotConfigurationManager` to switch the iPhone onto the camera's AP during `ingest()`.
5. Add the following to `Info.plist`:
   - `NSBluetoothAlwaysUsageDescription`
   - `NSLocationWhenInUseUsageDescription` (iOS gates Wi-Fi join behind location)
   - `NSLocalNetworkUsageDescription` (the camera's HTTP file server is on the local subnet)

Because `SyncFieldInsta360` uses `#if canImport(INSCameraServiceSDK)`, it picks the linked framework up automatically the next time you build — no per-target setting changes are needed.

## Verifying the link

Add a one-line check at app launch:

```swift
import SyncFieldInsta360

print("SyncFieldInsta360 v\(SyncFieldInsta360.version)")
let stream = Insta360CameraStream(streamId: "probe")
do { try await stream.prepare() } catch Insta360Error.frameworkNotLinked {
    fatalError("INSCameraServiceSDK.xcframework is not embedded in this app target")
}
```

If `prepare()` succeeds, the binary is linked. If it throws `frameworkNotLinked`, recheck the Embed & Sign setting.

## Public surface

```swift
public final class Insta360CameraStream: SyncFieldStream {
    public init(streamId: String)
    // Inherits all SyncFieldStream methods: prepare, connect, startRecording,
    // stopRecording, ingest, disconnect — driven by SessionOrchestrator.
}

public enum Insta360Error: Error {
    case frameworkNotLinked
    case notPaired
    case wifiCredentialsUnavailable
    case hotspotApplyFailed(String)
    case downloadFailed(String)
    case commandFailed(String)
    case cameraNotReachable
}

public enum SyncFieldInsta360 {
    public static let version: String   // == SyncFieldVersion.current
}
```

That's the entire customer-visible API. The BLE controller (`Insta360BLEController`) and WiFi downloader (`Insta360WiFiDownloader`) are internal.

## Stream lifecycle

`Insta360CameraStream` plugs into the standard `SessionOrchestrator` flow. The BLE pair / start-capture / stop-capture / WiFi download steps map to the orchestrator's lifecycle methods:

| Orchestrator method | What `Insta360CameraStream` does |
|---|---|
| `prepare()` | Compile-time framework check; throws `frameworkNotLinked` if missing |
| `connect()` | Scans BLE for the first `*go*` device (15 s timeout) and pairs |
| `startRecording()` | Sends BLE start-capture; records host-monotonic ns at ACK |
| `stopRecording()` | Sends BLE stop-capture; the SDK returns a camera-side file URI |
| `ingest()` | Fetches WiFi creds over BLE → switches iPhone onto the camera AP via `NEHotspotConfiguration` → downloads the mp4 → restores previous WiFi → writes `<streamId>.anchor.json` |
| `disconnect()` | Unpairs BLE |

The BLE-ACK monotonic timestamp is persisted as `<streamId>.anchor.json` next to the mp4 — the SyncField sync server uses it to align camera-internal PTS to the host monotonic domain.

## Typical use

```swift
import SyncField
import SyncFieldInsta360

let cam   = iPhoneCameraStream(streamId: "cam_ego")
let imu   = iPhoneMotionStream(streamId: "imu", rateHz: 100)
let wrist = Insta360CameraStream(streamId: "cam_wrist")

let session = SessionOrchestrator(hostId: "iphone_rig",
                                  outputDirectory: episodesDir)
try await session.add(cam)
try await session.add(imu)
try await session.add(wrist)

try await session.connect()           // BLE-pairs the wrist camera
try await session.startRecording()    // BLE start-capture + iPhone AVAssetWriter
//   ... user records ...
_ = try await session.stopRecording() // BLE stop-capture; iPhone closes mp4
_ = try await session.ingest { p in   // WiFi switch + camera mp4 download
    print("\(p.streamId): \(Int(p.fraction * 100))%")
}
try await session.disconnect()        // BLE unpair
```

A complete view-controller example: [`examples/ego-plus-wrist/EgoWristViewController.swift`](../examples/ego-plus-wrist/EgoWristViewController.swift).

## Gotchas

- **iOS forces a Wi-Fi rejoin** when you apply a hotspot configuration. `Insta360WiFiDownloader` snapshots the user's previous SSID via `CNCopyCurrentNetworkInfo` and restores it after the download — but if the user rejects the join prompt, the download fails with `Insta360Error.hotspotApplyFailed`.
- **Multiple Go 3S cameras on the same iPhone** are not supported by this single-device controller. Pair them sequentially across separate sessions, or extend `Insta360BLEController` to a multi-device version (out of scope for this SDK release).
- **`stopCapture` may return a stale URI** if the camera halted recording itself (overheat, full storage). The `INSCameraCaptureStopped` notification fires in that case; the controller currently logs it but does not surface a `HealthEvent` — handle the resulting `Insta360Error.commandFailed` by retrying or surfacing to the user.
- **The framework-not-linked branch is a hard error,** not a silent no-op. If you ship a build configuration that omits the xcframework, `prepare()` will throw on the first session. Use the launch-time check above to fail fast.

## Versioning

`SyncFieldInsta360.version` is re-exported from `SyncFieldVersion.current` — the optional module never drifts from the core release. Pin a single version of `syncfield-swift` and you are guaranteed matched core/optional behaviour.
