import Foundation

/// Why the camera halted a capture on its own, decoded from the
/// `INSCameraCaptureStoppedNotification` userInfo `error_code`
/// (`INSCaptureStoppedError` in `NSNotification+INSCamera.h`, a 0-based
/// NS_ENUM in declaration order).
///
/// Raw values are the stable strings used as the JS-side `reason`
/// discriminator and the PostHog event property — do not rename.
public enum Insta360CaptureStopReason: String, CaseIterable, Sendable {
    case overTimeLimit = "over_time_limit"
    case storageFull = "storage_full"
    case other = "other"
    case overFileNumberLimit = "over_file_number_limit"
    case lowCardSpeed = "low_card_speed"
    case muxerStreamError = "muxer_stream_error"
    case dropFrames = "drop_frames"
    case lowBattery = "low_battery"

    public init?(sdkErrorCode: UInt) {
        switch sdkErrorCode {
        case 0: self = .overTimeLimit
        case 1: self = .storageFull
        case 2: self = .other
        case 3: self = .overFileNumberLimit
        case 4: self = .lowCardSpeed
        case 5: self = .muxerStreamError
        case 6: self = .dropFrames
        case 7: self = .lowBattery
        default: return nil
        }
    }
}

/// Why the camera says it is about to power off, decoded from
/// `INSCameraWillShutDownNotification` userInfo `error_code`
/// (`INSCameraShutdownErrorCode`: 0 = battery run-out, 1 = temperature
/// over limit). A missing or unrecognized code degrades to `.unknown`.
public enum Insta360ShutdownReason: String, Sendable {
    case batteryRunout = "battery_runout"
    case temperatureOverLimit = "temperature_over_limit"
    case unknown = "unknown"

    public init(sdkErrorCode: UInt?) {
        switch sdkErrorCode {
        case 0: self = .batteryRunout
        case 1: self = .temperatureOverLimit
        default: self = .unknown
        }
    }
}

/// Snapshot of a confirmed mid-recording self-stop, kept until the next
/// commanded stop consumes it: a camera that already reported its capture
/// dead must not be walked through the BLE stop-retry ladder.
struct Insta360SelfStopRecord: Sendable {
    let reason: Insta360CaptureStopReason?
    let cameraDurationSec: UInt?
    let wallClockMs: UInt64
}

/// Which detection path confirmed a mid-recording capture stop.
public enum Insta360CaptureStopDetectionSource: String, Sendable {
    /// SDK push notification arrived AND this controller's own
    /// capture-state probe confirmed the camera is no longer capturing.
    case pushConfirmed = "push_confirmed"
    /// SDK push notification arrived but the probe could not run
    /// (command channel down) — attribution is best-effort.
    case pushUnverified = "push_unverified"
    /// The periodic capture-state watchdog observed the camera idle
    /// while a recording was supposed to be active. Works with no push
    /// delivery at all, which is the guaranteed detection path.
    case watchdog = "watchdog"
}

/// Poll cadence + confirmation policy for the mid-recording capture
/// watchdog. Pure so the confirmation rule stays unit-testable.
enum Insta360CaptureWatchdogPolicy {
    /// Seconds between capture-state probes while a recording is active.
    static let pollIntervalSeconds: TimeInterval = 10

    /// Consecutive "not capturing" reads required before declaring the
    /// recording dead. Two reads (~20 s worst case) filter any transient
    /// idle state around the camera's 18-minute auto-split boundary.
    static let confirmThreshold = 2

    static func shouldConfirmStop(consecutiveIdleReads: Int) -> Bool {
        consecutiveIdleReads >= confirmThreshold
    }
}
