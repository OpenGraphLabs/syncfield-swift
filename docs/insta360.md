# SyncFieldInsta360

Optional Swift module for syncing an Insta360 Go 3S wrist camera with iPhone capture, time aligned through the same `SessionOrchestrator`. Skip this document if your rig does not include an Insta360 camera.

The module depends on `INSCameraServiceSDK.xcframework`, a binary distributed by Insta360. Without it, every method on `Insta360CameraStream` throws `Insta360Error.frameworkNotLinked`. The rest of `syncfield-swift` runs unchanged.

## Get the Insta360 SDK

Insta360 does not publish the binary on SPM, CocoaPods, or any direct download page. You request a copy and drag the xcframeworks into your Xcode project.

1. Go to https://www.insta360.com/sdk/apply.
2. Submit the application form (company, use case, target camera).
3. Insta360 reviews requests manually. Approval typically arrives by email within a few business days.
4. The email links to the SDK bundle.

The bundle contains a sample iOS project plus four xcframeworks:

| Framework | Used by `SyncFieldInsta360` |
|---|---|
| `INSCameraServiceSDK.xcframework` | yes, BLE control and Wi-Fi info |
| `INSCameraSDK.xcframework` | linker dependency |
| `INSCoreMedia.xcframework` | linker dependency |
| `SSZipArchive.xcframework` | linker dependency |

Latest stable when this guide was written: **V1.9.2** (November 2025). The companion sample repo is public at https://github.com/Insta360Develop/CameraSDK-iOS, but the binaries themselves are only distributed through the application form above.

The Insta360 SDK license forbids redistributing the binaries. Do not commit them to a public repo.

> **Camera compatibility note**. The Insta360 SDK README lists X5, X4 Air, X4, X3, ONE X2, ONE X, ONE RS, and ONE RS 1-Inch. The Go 3S is not in their public list, but works through the same `INSCameraServiceSDK.xcframework` BLE and Wi-Fi flow. We test `syncfield-swift` against the Go 3S. If you target a different Insta360 model, validate the BLE pairing flow first.

## Drop into Xcode

1. Place all four xcframeworks under your project tree, e.g. `Vendor/Insta360/`.
2. Open your **app target** in Xcode, then **General > Frameworks, Libraries, and Embedded Content**. Drag all four xcframeworks in. Set each to **Embed & Sign**.
3. Open the app target's **Build Settings** and add `TO_B_SDK=1` to **Preprocessor Macros**. This flag is required by the Insta360 SDK.
4. The xcframeworks pull in CoreBluetooth, NetworkExtension, and SystemConfiguration transitively. Xcode resolves these for you.

When developing `SyncFieldInsta360` from a local checkout, the package target
also needs to see the Insta360 framework search path while SwiftPM resolves the
manifest. Set `SYNCFIELD_INSTA360_SDK_PATH` to the full path of
`INSCameraServiceSDK.xcframework`, or keep `syncfield-swift` next to `og-skill`
so the local development path is auto-detected. Set
`SYNCFIELD_DISABLE_LOCAL_INSTA360_SDK=1` to force the no-framework fallback.

## Capabilities and permissions

On the app target:

- Capability: **Hotspot Configuration**
- `Info.plist` keys:
  - `NSBluetoothAlwaysUsageDescription`
  - `NSLocationWhenInUseUsageDescription` (iOS gates Wi-Fi join behind location)
  - `NSLocalNetworkUsageDescription` (the camera HTTP file server is on the local subnet)

## Verify the link

```swift
import SyncFieldInsta360

print("SyncFieldInsta360 v\(SyncFieldInsta360.version)")

let probe = Insta360CameraStream(streamId: "probe")
do {
    try await probe.prepare()
} catch Insta360Error.frameworkNotLinked {
    fatalError("INSCameraServiceSDK.xcframework is not embedded in this target")
}
```

If `prepare()` returns, the binary is linked. A `frameworkNotLinked` throw means recheck the Embed & Sign setting and the `TO_B_SDK=1` macro.

## Use it

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

try await session.connect()         // BLE pair with the wrist camera
try await session.startRecording()  // BLE start capture
_ = try await session.stopRecording()
_ = try await session.ingest { p in
    print("\(p.streamId): \(Int(p.fraction * 100))%")
}
try await session.disconnect()
```

Lifecycle map:

| Method | What `Insta360CameraStream` does |
|---|---|
| `connect()` | Scan BLE for the first `*go*` device (15s timeout), pair |
| `startRecording()` | BLE start capture, record host monotonic ns at ACK |
| `stopRecording()` | BLE stop capture, returns the camera side file URI |
| `ingest()` | Fetch Wi-Fi creds over BLE, switch iPhone to camera AP, download mp4, restore Wi-Fi, write `<streamId>.anchor.json` |
| `disconnect()` | BLE unpair |

The BLE ACK monotonic timestamp in `<streamId>.anchor.json` lets the SyncField sync server align the camera internal PTS to the host monotonic domain.

Full view controller example: [`examples/ego-plus-wrist/EgoWristViewController.swift`](../examples/ego-plus-wrist/EgoWristViewController.swift).

## Multi-camera

For multiple Go 3S cameras, scan first, identify each physical device, then bind each stream to the chosen CoreBluetooth UUID. Role labels such as `left`, `right`, or `tripod` belong in your app; the SDK owns only discovery, identify, UUID binding, pairing, heartbeat, recording, and ingest.

```swift
var discovered: [DiscoveredInsta360] = []
for await camera in try await Insta360Scanner.shared.scan() {
    discovered.append(camera)
    if discovered.count == 2 { break }
}
await Insta360Scanner.shared.stopScan()

for camera in discovered {
    try await Insta360Scanner.shared.identify(uuid: camera.uuid)
    // App UI asks the user which role just flashed/clicked.
}

let wristL = Insta360CameraStream(streamId: "cam_wrist_left", uuid: leftUUID)
let wristR = Insta360CameraStream(streamId: "cam_wrist_right", uuid: rightUUID)
try await session.add(wristL)
try await session.add(wristR)
```

`Insta360CameraStream(streamId:)` is still available for a single camera. In a
multi-camera rig, prefer the UUID initializer; otherwise BLE scan order decides
which physical camera each stream claims.

## Gotchas

- **Wi-Fi rejoin prompt**. iOS shows a system prompt the first time the app applies a hotspot config. If the user declines, `ingest()` throws `Insta360Error.hotspotApplyFailed`.
- **Self stopped capture**. If the camera halts recording itself (overheat, full storage), `stopRecording()` may throw `commandFailed`. Surface the error to the user, do not retry blindly.
- **Duplicate UUID binding**. Binding the same UUID to two live streams throws `Insta360Error.uuidAlreadyBound`.
- **Version pinning**. `SyncFieldInsta360.version` re-exports `SyncFieldVersion.current`, so the optional module always tracks the core release.
