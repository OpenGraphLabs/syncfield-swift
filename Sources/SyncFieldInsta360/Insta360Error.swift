import Foundation

#if os(iOS) && canImport(NetworkExtension)
import NetworkExtension
#endif

public enum UploadWiFiApplyFailureKind: String, Codable, Equatable, Sendable {
    case userDenied
    case notInForeground
    case systemConfigFailed
    case unknown

    #if os(iOS) && canImport(NetworkExtension)
    public static func classify(_ error: NSError) -> UploadWiFiApplyFailureKind {
        guard error.domain == NEHotspotConfigurationErrorDomain else {
            return .unknown
        }
        switch error.code {
        case NEHotspotConfigurationError.userDenied.rawValue:
            return .userDenied
        case NEHotspotConfigurationError.applicationIsNotInForeground.rawValue:
            return .notInForeground
        case NEHotspotConfigurationError.systemConfiguration.rawValue:
            return .systemConfigFailed
        default:
            return .unknown
        }
    }
    #else
    public static func classify(_: NSError) -> UploadWiFiApplyFailureKind {
        .unknown
    }
    #endif
}

public enum Insta360Error: Error, CustomStringConvertible, LocalizedError {
    case frameworkNotLinked
    case notPaired
    case wifiCredentialsUnavailable
    case hotspotApplyFailed(String)
    case hotspotApplyFailedWithKind(kind: UploadWiFiApplyFailureKind, detail: String)
    case downloadFailed(String)
    case commandFailed(String)
    case notRecordingActionCam(String)
    case cameraNotReachable

    // Bridge-level wrist-pairing errors
    case invalidWristRole(String)
    case notConnected
    case roleAlreadyPaired(String)
    case missingUUID
    case roleConflict
    case pairInProgress(String)

    // Hub-level errors (Phase A)
    case scanAlreadyActive
    case deviceNotDiscovered(String)    // uuid
    case deviceNotPaired(String)        // uuid
    case uuidAlreadyBound(String)       // uuid
    case identifyPhotoFailed(String)

    // Collect-level errors (Phase C)
    case pendingSidecarInvalid(String)
    case collectTimeout(String)          // streamId

    // Camera-side transcode errors (fast-collect path)
    case transcodeFailed(String)

    // GO 3S phone-level authorization errors
    case phoneAuthorizationRequired(uuid: String, deviceId: String)
    case phoneAuthorizationRejected
    case phoneAuthorizationTimedOut
    case phoneAuthorizationCanceled
    case phoneAuthorizationSystemBusy
    case phoneAuthorizationConnectedByOtherDevice(String)

    public var description: String {
        switch self {
        case .frameworkNotLinked:
            return "Insta360Error: INSCameraServiceSDK.xcframework is not linked in the host app"
        case .notPaired:
            return "Insta360Error: camera is not paired — call connect() first"
        case .wifiCredentialsUnavailable:
            return "Insta360Error: camera did not provide WiFi SSID/passphrase over BLE"
        case .hotspotApplyFailed(let detail):
            return "Insta360Error: NEHotspotConfiguration apply failed (\(detail))"
        case .hotspotApplyFailedWithKind(let kind, let detail):
            return "Insta360Error: NEHotspotConfiguration apply failed [\(kind.rawValue)] (\(detail))"
        case .downloadFailed(let detail):
            return "Insta360Error: \(detail)"
        case .commandFailed(let detail):
            return "Insta360Error: BLE command failed (\(detail))"
        case .notRecordingActionCam(let detail):
            return "Insta360Error: paired BLE peripheral is not a recording ActionCam (\(detail))"
        case .cameraNotReachable:
            return "Insta360Error: camera AP reachable timeout at 192.168.42.1"
        case .invalidWristRole(let raw):
            return "wrist role must be 'left' or 'right', got: \(raw)"
        case .notConnected:
            return "SyncField bridge is not connected (call connect() first)"
        case .roleAlreadyPaired(let role):
            return "wrist role already paired: \(role)"
        case .missingUUID:
            return "pairStandalone succeeded but no UUID returned"
        case .roleConflict:
            return "camera already claimed under another wrist role"
        case .pairInProgress(let role):
            return "pair already in progress for wrist role: \(role)"
        case .scanAlreadyActive:
            return "Insta360Error: BLE scan is already active"
        case .deviceNotDiscovered(let uuid):
            return "Insta360Error: device \(uuid) not seen in recent scan"
        case .deviceNotPaired(let uuid):
            return "Insta360Error: device \(uuid) is not currently paired"
        case .uuidAlreadyBound(let uuid):
            return "Insta360Error: device \(uuid) is already bound to another Insta360CameraStream"
        case .identifyPhotoFailed(let detail):
            return "Insta360Error: takePicture failed (\(detail))"
        case .pendingSidecarInvalid(let reason):
            return "Insta360Error: pending sidecar invalid (\(reason))"
        case .collectTimeout(let streamId):
            return "Insta360Error: collect timeout for \(streamId)"
        case .transcodeFailed(let detail):
            return "Insta360Error: camera-side transcode failed (\(detail))"
        case .phoneAuthorizationRequired(let uuid, let deviceId):
            return "Insta360Error: phone authorization required for \(uuid) (deviceId: \(deviceId))"
        case .phoneAuthorizationRejected:
            return "Insta360Error: phone authorization rejected on camera"
        case .phoneAuthorizationTimedOut:
            return "Insta360Error: phone authorization timed out"
        case .phoneAuthorizationCanceled:
            return "Insta360Error: phone authorization canceled"
        case .phoneAuthorizationSystemBusy:
            return "Insta360Error: camera is busy during phone authorization"
        case .phoneAuthorizationConnectedByOtherDevice(let detail):
            return "Insta360Error: camera is connected by another device (\(detail))"
        }
    }

    /// `LocalizedError.errorDescription` is what `NSError.localizedDescription`
    /// surfaces — the bridge forwards this string to JS via `reject(code, msg, err)`.
    public var errorDescription: String? { description }
}
