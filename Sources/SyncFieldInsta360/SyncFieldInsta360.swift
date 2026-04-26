import Foundation
import SyncField

/// Namespace for the Insta360 Go 3S adapter. When the host app links
/// `INSCameraServiceSDK.xcframework`, `Insta360CameraStream` becomes
/// usable; otherwise only this version marker is exposed.
///
/// The version is re-exported from `SyncFieldVersion.current` so this
/// optional module never drifts from the core SDK release.
public enum SyncFieldInsta360 {
    public static let version = SyncFieldVersion.current
}
