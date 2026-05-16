import XCTest
@testable import SyncFieldInsta360

final class Insta360BackgroundSupervisorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InstaLog.mirrorToNSLog = false
        InstaLog.minLevel = .warn
        Insta360CoordinatorConfig.shared.backgroundBLEEnabled = true
    }

    override func tearDown() async throws {
        InstaLog.mirrorToNSLog = true
        await Insta360ConnectionCoordinator.shared.detachAll()
    }

    func testHandleBackgroundFansOutEventToEverySupervisor() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "L", role: "left")
        _ = await coord.attach(bindingKey: "R", role: "right")
        // Drive both to bleReady so the background event has somewhere to go.
        await coord.feed(bindingKey: "L", event: .scanHit(rssi: -65))
        await coord.feed(bindingKey: "L", event: .readinessProbeAck(elapsedMs: 100))
        await coord.feed(bindingKey: "R", event: .scanHit(rssi: -70))
        await coord.feed(bindingKey: "R", event: .readinessProbeAck(elapsedMs: 100))

        let bg = Insta360BackgroundSupervisor(coordinator: coord,
                                              recordingActiveProvider: { false })
        bg.handleBackground()
        // Wait for the fan-out task to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let healthL = await coord.health(bindingKey: "L")?.state
        let healthR = await coord.health(bindingKey: "R")?.state
        XCTAssertEqual(healthL, .bleSuspended)
        XCTAssertEqual(healthR, .bleSuspended)
    }

    func testHandleBackgroundWhileRecordingDoesNotSuspend() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "L", role: "left")
        await coord.feed(bindingKey: "L", event: .scanHit(rssi: -65))
        await coord.feed(bindingKey: "L", event: .readinessProbeAck(elapsedMs: 100))

        let bg = Insta360BackgroundSupervisor(coordinator: coord,
                                              recordingActiveProvider: { true })
        bg.handleBackground()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let healthL = await coord.health(bindingKey: "L")?.state
        XCTAssertEqual(healthL, .bleReady,
                       "should keep BLE alive while recording active")
    }

    func testHandleForegroundResumesSuspendedSupervisors() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "L", role: "left")
        await coord.feed(bindingKey: "L", event: .scanHit(rssi: -65))
        await coord.feed(bindingKey: "L", event: .readinessProbeAck(elapsedMs: 100))
        await coord.feed(bindingKey: "L", event: .backgroundEntered(recordingActive: false))

        let suspended = await coord.health(bindingKey: "L")?.state
        XCTAssertEqual(suspended, .bleSuspended)

        let bg = Insta360BackgroundSupervisor(coordinator: coord)
        bg.handleForeground()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let resumed = await coord.health(bindingKey: "L")?.state
        XCTAssertEqual(resumed, .searching)
    }

    func testBackgroundDisabledIsNoop() async {
        Insta360CoordinatorConfig.shared.backgroundBLEEnabled = false
        defer { Insta360CoordinatorConfig.shared.backgroundBLEEnabled = true }
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "L", role: "left")
        await coord.feed(bindingKey: "L", event: .scanHit(rssi: -65))
        await coord.feed(bindingKey: "L", event: .readinessProbeAck(elapsedMs: 100))
        // Supervisor itself respects config — feed should be a no-op.
        await coord.feed(bindingKey: "L", event: .backgroundEntered(recordingActive: false))
        let state = await coord.health(bindingKey: "L")?.state
        XCTAssertEqual(state, .bleReady, "config off means no suspension")
    }
}
