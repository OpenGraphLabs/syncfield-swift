import Foundation

public enum Insta360Error: Error, CustomStringConvertible {
    case frameworkNotLinked
    case notPaired
    case wifiCredentialsUnavailable
    case hotspotApplyFailed(String)
    case downloadFailed(String)
    case commandFailed(String)
    case cameraNotReachable

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
        case .downloadFailed(let detail):
            return "Insta360Error: \(detail)"
        case .commandFailed(let detail):
            return "Insta360Error: BLE command failed (\(detail))"
        case .cameraNotReachable:
            return "Insta360Error: camera AP reachable timeout at 192.168.42.1"
        }
    }
}
