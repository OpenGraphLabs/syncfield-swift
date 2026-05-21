// Tests/SyncFieldTests/iPhoneCameraStreamDeviceGateTests.swift
//
// Tests for the strict ultra-wide device gate. The host app calls
// `iPhoneCameraStream.isDeviceSupported()` at startup to decide whether to
// route into the recording UI or show an unsupported-device screen.

import XCTest
@testable import SyncField

final class iPhoneCameraStreamDeviceGateTests: XCTestCase {
    #if !os(iOS)
    /// On macOS / non-iOS the SDK has no ultra-wide camera available, so the
    /// gate must always report unsupported. This keeps the API contract
    /// sharp and lets unit tests run on macOS without an AVCaptureSession.
    func test_isDeviceSupported_returns_false_on_non_ios_platform() {
        XCTAssertFalse(iPhoneCameraStream.isDeviceSupported())
    }
    #endif

    /// Static helper must be callable without constructing an AVCaptureSession
    /// or allocating an iPhoneCameraStream instance. Apps invoke this at
    /// startup, before camera permission is granted.
    func test_isDeviceSupported_is_callable_as_static_without_instance() {
        // If the helper signature or accessibility regresses, this won't compile.
        let _: Bool = iPhoneCameraStream.isDeviceSupported()
    }
}
