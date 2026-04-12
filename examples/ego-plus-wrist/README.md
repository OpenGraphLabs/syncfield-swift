# ego-plus-wrist integration

Captures iPhone camera + IMU + Insta360 Go 3S wrist camera. The Go 3S is
triggered over BLE, and the mp4 is downloaded over WiFi during the
`ingest()` phase — the SDK switches the iPhone onto the camera's AP
automatically via `NEHotspotConfiguration` and restores the previous
WiFi on completion.

## Host app setup

### Xcode capabilities

Add these to your target's Signing & Capabilities pane:

1. **Hotspot Configuration** — grants `com.apple.developer.networking.HotspotConfiguration`. No Apple special approval required; available to every paid Developer account.
2. **Background Modes** (optional, recommended) — enable "Audio" and "Uses Bluetooth LE accessories" if you want recordings to continue while the app is backgrounded.

### Info.plist keys

| Key | Reason |
|---|---|
| `NSCameraUsageDescription` | iPhone camera capture |
| `NSMicrophoneUsageDescription` | Audio track + chirp alignment |
| `NSMotionUsageDescription` | CoreMotion IMU |
| `NSBluetoothAlwaysUsageDescription` | Pair with Insta360 over BLE |
| `NSLocationWhenInUseUsageDescription` | iOS sometimes requires this to apply a WiFi configuration by SSID |

### Insta360 SDK (customer-provided)

The `SyncFieldInsta360` target does **not** bundle the Insta360 binaries
— Insta360 distributes them under a Developer Program agreement. Drop
`INSCameraServiceSDK.xcframework` into your app target:

1. Obtain the xcframework from Insta360's Developer portal
2. In Xcode, drag it into **Frameworks, Libraries, and Embedded Content**
3. Set "Embed & Sign"

When linked, `#if canImport(INSCameraServiceSDK)` resolves true and
`Insta360CameraStream` becomes functional. When absent, any call into
the stream throws `Insta360Error.frameworkNotLinked` — the rest of
SyncField (iPhone camera, IMU, Tactile) is unaffected.
