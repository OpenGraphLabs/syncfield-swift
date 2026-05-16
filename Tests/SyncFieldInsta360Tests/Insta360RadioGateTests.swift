import XCTest
@testable import SyncFieldInsta360

final class Insta360RadioGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InstaLog.mirrorToNSLog = false
        InstaLog.minLevel = .warn
        let c = Insta360CoordinatorConfig.shared
        c.radioGateEnabled = true
        c.heartbeatIntervalMs = 2_000
        c.radioGateSlowHeartbeatIntervalMs = 8_000
    }

    override func tearDown() {
        InstaLog.mirrorToNSLog = true
        super.tearDown()
    }

    // MARK: - Helpers

    private func assertNilLeaseHolder(_ gate: Insta360RadioGate,
                                       file: StaticString = #file,
                                       line: UInt = #line) async {
        let holder = await gate.currentLeaseHolderBindingKey()
        XCTAssertNil(holder, file: file, line: line)
    }

    /// Records heartbeat-interval setter invocations.
    private actor HeartbeatRecorder {
        var calls: [(key: String, ms: UInt64?)] = []
        func record(_ key: String, _ ms: UInt64?) { calls.append((key, ms)) }
        func slowModeAppliedTo(_ key: String) -> Bool {
            calls.contains { $0.key == key && $0.ms == 8_000 }
        }
        func suspendedFor(_ key: String) -> Bool {
            calls.contains { $0.key == key && $0.ms == nil }
        }
        func restoredFor(_ key: String) -> Bool {
            calls.contains { $0.key == key && $0.ms == 2_000 }
        }
    }

    private actor EventRecorder {
        var events: [(key: String, event: Insta360SupervisorEvent)] = []
        func record(_ key: String, _ event: Insta360SupervisorEvent) {
            events.append((key, event))
        }
        func received(_ event: Insta360SupervisorEvent, for key: String) -> Bool {
            events.contains { $0.key == key && $0.event == event }
        }
    }

    private func makeGate() -> (Insta360RadioGate, HeartbeatRecorder, EventRecorder) {
        let hb = HeartbeatRecorder()
        let evt = EventRecorder()
        let gate = Insta360RadioGate(
            config: .shared,
            setHeartbeatIntervalMs: { key, ms in
                await hb.record(key, ms)
            },
            emitSupervisorEvent: { key, event in
                await evt.record(key, event)
            })
        return (gate, hb, evt)
    }

    // MARK: - Single camera

    func testSingleCameraAcquireReleaseRestoresHeartbeat() async {
        let (gate, hb, evt) = makeGate()
        await gate.register(bindingKey: "L")
        let lease = await gate.acquireWiFi(bindingKey: "L")
        XCTAssertEqual(lease.bindingKey, "L")
        let suspendedL = await hb.suspendedFor("L")
        let acquiredL = await evt.received(.wifiAcquired, for: "L")
        XCTAssertTrue(suspendedL)
        XCTAssertTrue(acquiredL)

        await gate.releaseWiFi(lease)
        let restoredL = await hb.restoredFor("L")
        let releasedL = await evt.received(.wifiReleased, for: "L")
        XCTAssertTrue(restoredL)
        XCTAssertTrue(releasedL)
    }

    // MARK: - Multi-camera serialization

    func testSecondCameraBlocksUntilFirstReleases() async {
        let (gate, _, _) = makeGate()
        await gate.register(bindingKey: "L")
        await gate.register(bindingKey: "R")
        let firstLease = await gate.acquireWiFi(bindingKey: "L")
        var holder = await gate.currentLeaseHolderBindingKey()
        XCTAssertEqual(holder, "L")

        // Kick off the R acquire, then release L; R should acquire next.
        let rAcquired = expectation(description: "R acquired after L release")
        Task {
            let r = await gate.acquireWiFi(bindingKey: "R")
            XCTAssertEqual(r.bindingKey, "R")
            rAcquired.fulfill()
        }
        try? await Task.sleep(nanoseconds: 30_000_000)  // ensure R is waiting
        holder = await gate.currentLeaseHolderBindingKey()
        XCTAssertEqual(holder, "L", "L should still hold the lease")

        await gate.releaseWiFi(firstLease)
        await fulfillment(of: [rAcquired], timeout: 1)
        holder = await gate.currentLeaseHolderBindingKey()
        XCTAssertEqual(holder, "R")
    }

    func testWhileOneCameraHoldsTheOtherIsInSlowMode() async {
        let (gate, hb, _) = makeGate()
        await gate.register(bindingKey: "L")
        await gate.register(bindingKey: "R")
        _ = await gate.acquireWiFi(bindingKey: "L")
        let suspendedL = await hb.suspendedFor("L")
        let slowR = await hb.slowModeAppliedTo("R")
        XCTAssertTrue(suspendedL)
        XCTAssertTrue(slowR)
    }

    // MARK: - withWiFi guarantees release

    func testWithWiFiReleasesOnSuccess() async {
        let (gate, hb, _) = makeGate()
        await gate.register(bindingKey: "L")
        let result = await gate.withWiFi(bindingKey: "L") { _ in
            return 42
        }
        XCTAssertEqual(result, 42)
        await assertNilLeaseHolder(gate)
        let restored = await hb.restoredFor("L")
        XCTAssertTrue(restored)
    }

    func testWithWiFiReleasesOnThrow() async throws {
        let (gate, _, _) = makeGate()
        await gate.register(bindingKey: "L")
        struct DummyError: Error {}
        do {
            try await gate.withWiFi(bindingKey: "L") { _ -> Void in
                throw DummyError()
            }
            XCTFail("should have thrown")
        } catch is DummyError {
            // expected
        }
        await assertNilLeaseHolder(gate)
    }

    // MARK: - Gate disabled passthrough

    func testGateDisabledIsPassthrough() async {
        Insta360CoordinatorConfig.shared.radioGateEnabled = false
        defer { Insta360CoordinatorConfig.shared.radioGateEnabled = true }
        let (gate, hb, evt) = makeGate()
        await gate.register(bindingKey: "L")
        let lease = await gate.acquireWiFi(bindingKey: "L")
        XCTAssertEqual(lease.bindingKey, "L")
        // No heartbeat changes when gate is disabled
        let suspended = await hb.suspendedFor("L")
        let acquired = await evt.received(.wifiAcquired, for: "L")
        XCTAssertFalse(suspended)
        XCTAssertFalse(acquired)
    }
}
