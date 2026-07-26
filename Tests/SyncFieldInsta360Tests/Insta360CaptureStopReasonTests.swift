import XCTest
@testable import SyncFieldInsta360

final class Insta360CaptureStopReasonTests: XCTestCase {

    // `INSCaptureStoppedError` is a 0-based NS_ENUM declared in
    // `NSNotification+INSCamera.h`; the mapping must follow declaration
    // order exactly or every field diagnosis is mislabeled.
    func test_stopReasonMapsEverySDKErrorCodeInDeclarationOrder() {
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 0), .overTimeLimit)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 1), .storageFull)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 2), .other)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 3), .overFileNumberLimit)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 4), .lowCardSpeed)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 5), .muxerStreamError)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 6), .dropFrames)
        XCTAssertEqual(Insta360CaptureStopReason(sdkErrorCode: 7), .lowBattery)
    }

    func test_stopReasonRejectsUnknownCodes() {
        XCTAssertNil(Insta360CaptureStopReason(sdkErrorCode: 8))
        XCTAssertNil(Insta360CaptureStopReason(sdkErrorCode: UInt.max))
    }

    // Raw values are the JS-side discriminator and the PostHog `reason`
    // property; renaming one silently breaks dashboards.
    func test_stopReasonRawValuesAreStable() {
        XCTAssertEqual(Insta360CaptureStopReason.overTimeLimit.rawValue, "over_time_limit")
        XCTAssertEqual(Insta360CaptureStopReason.storageFull.rawValue, "storage_full")
        XCTAssertEqual(Insta360CaptureStopReason.other.rawValue, "other")
        XCTAssertEqual(Insta360CaptureStopReason.overFileNumberLimit.rawValue, "over_file_number_limit")
        XCTAssertEqual(Insta360CaptureStopReason.lowCardSpeed.rawValue, "low_card_speed")
        XCTAssertEqual(Insta360CaptureStopReason.muxerStreamError.rawValue, "muxer_stream_error")
        XCTAssertEqual(Insta360CaptureStopReason.dropFrames.rawValue, "drop_frames")
        XCTAssertEqual(Insta360CaptureStopReason.lowBattery.rawValue, "low_battery")
    }

    // `INSCameraShutdownErrorCode`: 0 = battery run-out, 1 = temperature
    // over limit. Anything else (including a missing code) must degrade to
    // `.unknown`, never crash or mislabel.
    func test_shutdownReasonMapping() {
        XCTAssertEqual(Insta360ShutdownReason(sdkErrorCode: 0), .batteryRunout)
        XCTAssertEqual(Insta360ShutdownReason(sdkErrorCode: 1), .temperatureOverLimit)
        XCTAssertEqual(Insta360ShutdownReason(sdkErrorCode: 2), .unknown)
        XCTAssertEqual(Insta360ShutdownReason(sdkErrorCode: nil), .unknown)
    }

    func test_detectionSourceRawValuesAreStable() {
        XCTAssertEqual(Insta360CaptureStopDetectionSource.pushConfirmed.rawValue, "push_confirmed")
        XCTAssertEqual(Insta360CaptureStopDetectionSource.pushUnverified.rawValue, "push_unverified")
        XCTAssertEqual(Insta360CaptureStopDetectionSource.watchdog.rawValue, "watchdog")
    }

    // Two consecutive idle reads (~20 s worst case at the 10 s cadence)
    // are required before declaring a recording dead, so a transient state
    // around the camera's 18-minute auto-split can't false-fire.
    func test_watchdogRequiresTwoConsecutiveIdleReads() {
        XCTAssertFalse(Insta360CaptureWatchdogPolicy.shouldConfirmStop(consecutiveIdleReads: 0))
        XCTAssertFalse(Insta360CaptureWatchdogPolicy.shouldConfirmStop(consecutiveIdleReads: 1))
        XCTAssertTrue(Insta360CaptureWatchdogPolicy.shouldConfirmStop(consecutiveIdleReads: 2))
        XCTAssertTrue(Insta360CaptureWatchdogPolicy.shouldConfirmStop(consecutiveIdleReads: 3))
    }

    func test_watchdogPollCadenceIsTenSeconds() {
        XCTAssertEqual(Insta360CaptureWatchdogPolicy.pollIntervalSeconds, 10)
    }

    // The warning enum's `kind` strings are the JS discriminator consumed
    // by `SyncFieldBridge.ts` — pinned here so a rename fails loudly.
    func test_cameraWarningKindsAreStable() {
        XCTAssertEqual(
            Insta360CameraWarning.captureStoppedUnexpectedly(
                deviceName: "GO 3S 8E13B7",
                reason: .lowBattery,
                cameraDurationSec: 123,
                source: .watchdog).kind,
            "captureStopped")
        XCTAssertEqual(
            Insta360CameraWarning.willShutdown(
                deviceName: "GO 3S 8E13B7",
                reason: .batteryRunout).kind,
            "willShutdown")
        XCTAssertEqual(
            Insta360CameraWarning.willShutdown(
                deviceName: "GO 3S 8E13B7",
                reason: .temperatureOverLimit).deviceName,
            "GO 3S 8E13B7")
    }

}
