import XCTest
@testable import SyncFieldInsta360

final class Insta360CameraSupervisorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InstaLog.mirrorToNSLog = false
        InstaLog.minLevel = .warn
        let c = Insta360CoordinatorConfig.shared
        c.autoReconnectEnabled = true
        c.radioGateEnabled = true
        c.backgroundBLEEnabled = true
        c.wakeUserPromptEnabled = true
        c.wakeStallThresholdSeconds = 12
        c.persistentScanWindowCount = 3
        c.persistentLastSeenThresholdSeconds = 90
    }

    override func tearDown() {
        InstaLog.mirrorToNSLog = true
        super.tearDown()
    }

    // MARK: - Helpers

    /// Workaround: XCTAssertEqual's autoclosure can't `await` so we hop into
    /// the actor explicitly to read the snapshot before asserting.
    private func assertStateEquals(_ sup: Insta360CameraSupervisor,
                                   _ expected: Insta360ConnectionState,
                                   _ message: String = "",
                                   file: StaticString = #file,
                                   line: UInt = #line) async {
        let actual = await sup.snapshot().state
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    /// Records every event the supervisor emits. Backed by an actor so it
    /// is safe to mutate from the supervisor's async observer callbacks
    /// without locking.
    private actor RecordingObserver {
        struct Transition: Sendable {
            let from: Insta360ConnectionState
            let to: Insta360ConnectionState
            let reason: String?
        }
        struct WakeStall: Sendable {
            let suggested: Insta360WakeStallSuggestedAction
        }
        private(set) var transitions: [Transition] = []
        private(set) var wakeStalls: [WakeStall] = []

        func recordTransition(from: Insta360ConnectionState,
                              to: Insta360ConnectionState,
                              reason: String?) {
            transitions.append(.init(from: from, to: to, reason: reason))
        }
        func recordWakeStall(_ suggested: Insta360WakeStallSuggestedAction) {
            wakeStalls.append(.init(suggested: suggested))
        }
        func snapshotTransitions() -> [Transition] { transitions }
        func snapshotWakeStalls() -> [WakeStall] { wakeStalls }
    }

    /// Build a closure observer that funnels into a `RecordingObserver` actor.
    private func makeObserver(recording: RecordingObserver) -> Insta360CameraSupervisorObserver {
        Insta360CameraSupervisorObserver(
            didTransition: { from, to, reason, _ in
                await recording.recordTransition(from: from, to: to, reason: reason)
            },
            didEmitWakeStallRequiringUser: { suggested, _ in
                await recording.recordWakeStall(suggested)
            })
    }

    private func makeSupervisor(autoReconnect: Bool = true,
                                wakeStallSec: TimeInterval = 12,
                                reconnectDriver: Insta360CameraSupervisor.ReconnectDriver? = nil)
        async -> (Insta360CameraSupervisor, RecordingObserver)
    {
        let c = Insta360CoordinatorConfig.shared
        c.autoReconnectEnabled = autoReconnect
        c.wakeStallThresholdSeconds = wakeStallSec
        let sup = Insta360CameraSupervisor(
            bindingKey: "AAA",
            role: "left",
            policy: Insta360ReconnectPolicy(
                backoffScheduleSeconds: [0.01, 0.01, 0.01, 0.01],
                maxAttempts: 4),
            config: c,
            reconnectDriver: reconnectDriver)
        let recorder = RecordingObserver()
        await sup.setObserver(makeObserver(recording: recorder))
        return (sup, recorder)
    }

    // MARK: - Happy path S1

    func testAttachThenScanHitThenReadinessProbeReachesBleReady() async {
        let (sup, obs) = await makeSupervisor()
        await Task.yield()  // let setObserver run
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeStarted)
        await sup.handle(.readinessProbeAck(elapsedMs: 120))

        let h = await sup.snapshot()
        XCTAssertEqual(h.state, .bleReady)
        XCTAssertEqual(h.rssi, -65)
        XCTAssertNotNil(h.lastSeenAtMs)
        XCTAssertNotNil(h.lastCommandSuccessAtMs)

        let transitions = (await obs.snapshotTransitions())
        XCTAssertEqual(transitions.map(\.to),
                       [.searching, .connecting, .bleReady])
    }

    // MARK: - Degraded + recovery (S3 partial)

    func testTwoConsecutiveHeartbeatMissesDegrade() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await assertStateEquals(sup, .bleReady)

        await sup.handle(.heartbeatMiss)
        await assertStateEquals(sup, .bleReady, "single miss is tolerated")
        await sup.handle(.heartbeatMiss)
        await assertStateEquals(sup, .bleDegraded)

        await sup.handle(.heartbeatAck(rssi: -68))
        await assertStateEquals(sup, .bleReady)
        let missesAfterAck = await sup.snapshot().consecutiveHeartbeatMisses
        XCTAssertEqual(missesAfterAck, 0)
    }

    func testLowRSSITriggersDegraded() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.rssiSample(-90))
        await assertStateEquals(sup, .bleDegraded)
    }

    // MARK: - Unsolicited disconnect → reconnecting

    func testUnsolicitedDisconnectTransitionsToReconnectingAndSchedulesDriver() async {
        let driverCalled = expectation(description: "reconnect driver invoked")
        let (sup, obs) = await makeSupervisor(
            reconnectDriver: { driverCalled.fulfill() })
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.unsolicitedDisconnect(error: "Connection lost"))

        await fulfillment(of: [driverCalled], timeout: 1)
        let states = (await obs.snapshotTransitions()).map(\.to)
        XCTAssertTrue(states.contains(.reconnecting),
                      "expected reconnecting transition, got \(states)")
    }

    func testDisconnectWithAutoReconnectDisabledGoesStraightToLost() async {
        let (sup, _) = await makeSupervisor(autoReconnect: false)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.unsolicitedDisconnect(error: "x"))
        await assertStateEquals(sup, .lost)
    }

    /// S3 third-run regression: even with the schedule-time debounce,
    /// a duplicate event queued *behind* the first slipped through during
    /// the first event's `await transition(...)` observer yield, because
    /// the schedule timestamp was still nil. The debounce must instead
    /// be set at the very top of the handler — before any await — so the
    /// queued duplicate observes it.
    func testDuplicateDisconnectsRacingTransitionAwaitAreStillDebounced() async {
        // A driver that takes a moment so the supervisor stays in
        // .reconnecting between events.
        let driverCalled = expectation(description: "driver called once")
        driverCalled.assertForOverFulfill = true
        let (sup, obs) = await makeSupervisor(reconnectDriver: {
            driverCalled.fulfill()
        })
        // Fire enough setup events to reach bleReady.
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))

        // Spawn two disconnect tasks concurrently — they race on actor
        // re-entrancy across the transition's observer await. With the
        // pre-await marker, only the first should pass.
        async let a: Void = sup.handle(.unsolicitedDisconnect(error: "primary"))
        async let b: Void = sup.handle(.unsolicitedDisconnect(error: "duplicate"))
        _ = await (a, b)

        await fulfillment(of: [driverCalled], timeout: 2)
        let scheduleEvents = (await obs.snapshotTransitions())
            .filter { $0.to == .reconnecting }
        XCTAssertEqual(scheduleEvents.count, 1,
                       "expected one reconnecting transition under race, got \(scheduleEvents.count)")
    }

    /// S3 regression: SDK fires `didDisconnectWithError` multiple times for
    /// the same drop (CoreBluetooth peripheral disconnect + INSCameraManager
    /// cleanup + `markConnectionStale` cascade). Without debounce, each fire
    /// reschedules reconnect and the attempt counter jumps 1 → 6 in ms,
    /// pushing first backoff from 500 ms to 15 s. Subsequent disconnects
    /// arriving inside the debounce window should be ignored.
    func testDuplicateUnsolicitedDisconnectsDoNotInflateAttemptCounter() async {
        let driverCalled = expectation(description: "reconnect driver invoked once")
        driverCalled.assertForOverFulfill = true
        let (sup, obs) = await makeSupervisor(reconnectDriver: {
            driverCalled.fulfill()
        })
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        // Three back-to-back disconnects within the debounce window.
        await sup.handle(.unsolicitedDisconnect(error: "primary"))
        await sup.handle(.unsolicitedDisconnect(error: "duplicate_a"))
        await sup.handle(.unsolicitedDisconnect(error: "duplicate_b"))

        await fulfillment(of: [driverCalled], timeout: 2)
        let scheduleEvents = (await obs.snapshotTransitions())
            .filter { $0.to == .reconnecting }
        XCTAssertEqual(scheduleEvents.count, 1,
                       "expected one reconnecting transition, got \(scheduleEvents.count)")
    }

    /// S3 regression: when a camera physically goes out of range, the heartbeat
    /// poll fails first (driving bleReady → bleDegraded), and CoreBluetooth
    /// surfaces the disconnect somewhat later. The supervisor must accept the
    /// disconnect from `.bleDegraded` and schedule reconnect, not get stuck
    /// in degraded state.
    func testDisconnectFromBleDegradedSchedulesReconnect() async {
        let driverCalled = expectation(description: "reconnect driver invoked")
        let (sup, obs) = await makeSupervisor(
            reconnectDriver: { driverCalled.fulfill() })
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        // Drive into bleDegraded via two heartbeat misses (matches the live
        // SDK flow: out-of-range camera = RSSI probe failures).
        await sup.handle(.heartbeatMiss)
        await sup.handle(.heartbeatMiss)
        await assertStateEquals(sup, .bleDegraded)
        // CoreBluetooth surfaces the disconnect — supervisor must accept it
        // even though current state is degraded, not bleReady.
        await sup.handle(.unsolicitedDisconnect(error: "timed out"))

        await fulfillment(of: [driverCalled], timeout: 1)
        let states = (await obs.snapshotTransitions()).map(\.to)
        XCTAssertTrue(states.contains(.reconnecting),
                      "expected reconnecting transition from bleDegraded, got \(states)")
    }

    // MARK: - Persistent classifier S9

    func testThreeEmptyScanWindowsClassifyAsLost() async {
        let (sup, obs) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanWindowClosedNoHit)
        await sup.handle(.scanWindowClosedNoHit)
        let stateAfter2 = await sup.snapshot().state
        XCTAssertNotEqual(stateAfter2, .lost)
        await sup.handle(.scanWindowClosedNoHit)
        await assertStateEquals(sup, .lost)

        let transitions = (await obs.snapshotTransitions())
        XCTAssertTrue(transitions.contains { $0.to == .lost })
    }

    // MARK: - WiFi gate (S4 component)

    func testWiFiAcquiredReleasedFlipsState() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.wifiAcquired)
        await assertStateEquals(sup, .wifiBound)
        let inFlight1 = await sup.snapshot().wifiInFlight
        XCTAssertTrue(inFlight1)
        await sup.handle(.wifiReleased)
        await assertStateEquals(sup, .bleReady)
        let inFlight2 = await sup.snapshot().wifiInFlight
        XCTAssertFalse(inFlight2)
    }

    // MARK: - Background + foreground (S5)

    func testBackgroundIdleSuspendsAndForegroundResumes() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.backgroundEntered(recordingActive: false))
        await assertStateEquals(sup, .bleSuspended)
        await sup.handle(.foregroundEntered)
        await assertStateEquals(sup, .searching)
    }

    func testBackgroundWhileRecordingKeepsBleReady() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.backgroundEntered(recordingActive: true))
        await assertStateEquals(sup, .bleReady,
                       "recording should not suspend BLE")
    }

    /// S5: foregroundEntered must not just transition state — it must also
    /// schedule a reconnect so the bridge's `reconnectDriver` runs
    /// `refreshConnection`. Without this the supervisor sits in `.searching`
    /// indefinitely after every backgrounding because nothing in the state
    /// machine itself drives a probe.
    func testForegroundFromSuspendedSchedulesReconnect() async {
        let driverCalled = expectation(description: "reconnect driver invoked on foreground")
        let (sup, _) = await makeSupervisor(reconnectDriver: {
            driverCalled.fulfill()
        })
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.backgroundEntered(recordingActive: false))
        await assertStateEquals(sup, .bleSuspended)
        await sup.handle(.foregroundEntered)
        await assertStateEquals(sup, .searching)

        // Driver must fire within the first backoff window (500 ms).
        await fulfillment(of: [driverCalled], timeout: 2)
    }

    // MARK: - Wake stall prompt (S2)

    func testWakeStallEmitsPromptWithPowerButtonByDefault() async {
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        // Cross the stall threshold.
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        // The stall check fires only on subsequent wakeCycleStarted; one more
        // is enough since the timestamp was set on the first cycle.
        await Task.yield()
        let stalls = await obs.snapshotWakeStalls()
        XCTAssertGreaterThanOrEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first?.suggested, .powerButton)
    }

    func testWakeStallSuggestsRemoveFromDockWhenDocked() async {
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.dockPolled(status: .docked))
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let stalls = await obs.snapshotWakeStalls()
        XCTAssertEqual(stalls.first?.suggested, .removeFromDock)
    }

    // MARK: - Real-signal wiring (S1 follow-up)

    func testHeartbeatAckRecordsRssiAndLastSeen() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 250))
        await sup.handle(.heartbeatAck(rssi: -67))
        let h = await sup.snapshot()
        XCTAssertEqual(h.rssi, -67)
        XCTAssertNotNil(h.lastSeenAtMs)
        XCTAssertNotNil(h.lastCommandSuccessAtMs)
        XCTAssertEqual(h.consecutiveHeartbeatMisses, 0)
    }

    func testHeartbeatAckRecoversFromDegraded() async {
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 250))
        await sup.handle(.heartbeatMiss)
        await sup.handle(.heartbeatMiss)
        await assertStateEquals(sup, .bleDegraded)
        await sup.handle(.heartbeatAck(rssi: -66))
        await assertStateEquals(sup, .bleReady)
    }

    func testReadinessProbeElapsedReachesHealthCommandTime() async {
        let (sup, _) = await makeSupervisor()
        let before = UInt64(Date().timeIntervalSince1970 * 1_000)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -60))
        await sup.handle(.readinessProbeAck(elapsedMs: 423))
        let h = await sup.snapshot()
        XCTAssertNotNil(h.lastCommandSuccessAtMs)
        XCTAssertGreaterThanOrEqual(h.lastCommandSuccessAtMs ?? 0, before)
        XCTAssertEqual(h.state, .bleReady)
    }

    // MARK: - recordingReadinessFailed surfaces modal at device-connect screen

    func testRecordingReadinessFailedTransitionsToLost() async {
        // Before this fix, supervisor stayed in `.searching` after a
        // readiness probe failure and accumulated wake events forever,
        // re-firing the modal every 12 s indefinitely. Now it transitions
        // to `.lost` so the state is explicit, and a subsequent pair
        // attempt (user re-tap of 사진 찍기 or "다시 시도") cleanly
        // re-enters `.searching`.
        let (sup, _) = await makeSupervisor(wakeStallSec: 600)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await assertStateEquals(sup, .bleReady)

        await sup.handle(.recordingReadinessFailed)
        await assertStateEquals(sup, .lost)
    }

    func testPairAttemptStartedCanExitLostState() async {
        // User-recoverable terminal: after `.lost`, the user taps
        // 사진 찍기 (identify) or 다음 (assignWristRole). Both feed
        // `.pairAttemptStarted`. We must transition back to `.searching`
        // — otherwise the supervisor is permanently stuck and even a
        // retry doesn't restart the connect flow.
        let (sup, _) = await makeSupervisor()
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.recordingReadinessFailed)
        await assertStateEquals(sup, .lost)

        await sup.handle(.pairAttemptStarted)
        await assertStateEquals(sup, .searching,
                                "user retry must exit .lost")
    }

    func testPairAttemptStartedDoesNotEscapeGiveUp() async {
        // `.giveUp` is the only truly terminal state — explicit detach
        // means the supervisor is being torn down. New events must not
        // resurrect it.
        let (sup, _) = await makeSupervisor()
        await sup.handle(.detached)
        await assertStateEquals(sup, .giveUp)
        await sup.handle(.pairAttemptStarted)
        await assertStateEquals(sup, .giveUp)
    }

    func testRecordingReadinessFailedEmitsImmediateWakeStallPrompt() async {
        // Bridge feeds this when refreshConnection's power probe fails
        // right after pair (typical when ActionPod is off while docked).
        // It must emit the wake-stall prompt without waiting for the
        // 12 s threshold — the user is at the discovery screen and the
        // phone is still in hand, so showing the guidance immediately is
        // the whole UX point.
        let (sup, obs) = await makeSupervisor(wakeStallSec: 600)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await assertStateEquals(sup, .bleReady)

        await sup.handle(.recordingReadinessFailed)
        await Task.yield()

        let stalls = await obs.snapshotWakeStalls()
        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first?.suggested, .powerButton)
    }

    func testRecordingReadinessFailedSuggestsRemoveFromDockWhenDocked() async {
        let (sup, obs) = await makeSupervisor(wakeStallSec: 600)
        await sup.handle(.attached)
        await sup.handle(.dockPolled(status: .docked))
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.recordingReadinessFailed)
        await Task.yield()
        let stalls = await obs.snapshotWakeStalls()
        XCTAssertEqual(stalls.first?.suggested, .removeFromDock)
    }

    func testRecordingReadinessFailedClearsStateForNextPrompt() async {
        // After firing, wake accumulator must reset so the next retry
        // cycle can re-fire when threshold elapses again.
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.recordingReadinessFailed)
        await Task.yield()
        let initialCount = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(initialCount, 1)

        // Simulate user retry — supervisor goes back to searching, a new
        // wake cycle starts the fresh 12 s window.
        await sup.handle(.forceReconnectRequested)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let count = (await obs.snapshotWakeStalls()).count
        XCTAssertGreaterThanOrEqual(count, 2,
                                    "wake-stall fires again on next retry cycle")
    }

    // MARK: - Wake events scoped to discovery states (post-stop false-alarm fix)

    func testWakeEventsIgnoredDuringReconnectingAfterStop() async {
        // Reproduces the user's report: after a successful recording is
        // stopped, the camera enters save mode → BLE briefly drops →
        // supervisor `bleReady → reconnecting`. The SDK's automatic
        // recovery does wake cycles, which would otherwise accumulate
        // and trip the 12 s threshold → false-alarm "전원 켜주세요" modal.
        // The fix: wake cycles only count toward the threshold while the
        // supervisor is actively searching/connecting (= in the user-
        // facing pair flow).
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await assertStateEquals(sup, .bleReady)

        // Recording finishes, BLE drops → supervisor recovers via reconnect.
        await sup.handle(.unsolicitedDisconnect(error: "stop_drop"))
        await assertStateEquals(sup, .reconnecting)

        // SDK retries with wake cycles during reconnect. None of these
        // should accumulate toward a wake-stall prompt.
        for _ in 0..<10 {
            await sup.handle(.wakeCycleStarted(strategy: "targeted"))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await Task.yield()
        let stalls = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(stalls, 0,
                       "no false-alarm wake stall during reconnect after stop")
    }

    func testWakeEventsIgnoredDuringBleReady() async {
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await assertStateEquals(sup, .bleReady)
        for _ in 0..<10 {
            await sup.handle(.wakeCycleStarted(strategy: "targeted"))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await Task.yield()
        let stalls = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(stalls, 0,
                       "wake events while bleReady do not fire prompt")
    }

    func testWakeEventsStillFireInSearchingState() async {
        // Regression guard: the gate must not be so strict that we lose
        // the original pair-time prompt. In `.searching`, wake events
        // must still accumulate to the 12 s threshold.
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await assertStateEquals(sup, .searching)
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let stalls = (await obs.snapshotWakeStalls()).count
        XCTAssertGreaterThanOrEqual(stalls, 1,
                                    "pair-time wake stall still fires")
    }

    // MARK: - Wake events ignored in terminal-ish states (modal storm fix)

    func testWakeEventsIgnoredInLostState() async {
        // Reproduces the "app 먹통" symptom: after `recording_readiness_failed`
        // transitioned the supervisor into `.lost`, the SDK's continuing
        // wake retry loop kept feeding `.wakeCycleStarted` events, which
        // re-tripped the 12 s threshold every cycle and bombarded the RN
        // modal with re-fire events. The fix: ignore wake cycles once
        // we're in a terminal state.
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.recordingReadinessFailed)
        await assertStateEquals(sup, .lost)
        let baselineCount = (await obs.snapshotWakeStalls()).count

        // Simulate SDK wake retries continuing for a long time.
        for _ in 0..<10 {
            await sup.handle(.wakeCycleStarted(strategy: "targeted"))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await Task.yield()
        let afterCount = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(afterCount, baselineCount,
                       "no additional wake-stall prompts in .lost state")
    }

    func testUserActionRequiredErrorTransitionsBackToLost() async {
        // After `forceReconnectRequested` from a `.lost` state, the
        // supervisor enters `.searching` and the reconnect driver runs.
        // If the driver throws "user_action_required" (signalling that
        // the bridge can't transparently re-pair), the supervisor must
        // transition back to `.lost` and STOP the backoff loop. Without
        // this guard the supervisor would retry the same failing driver
        // forever.
        let driverError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "user_action_required"])
        let (sup, _) = await makeSupervisor(
            reconnectDriver: { throw driverError })
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -55))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.recordingReadinessFailed)
        await assertStateEquals(sup, .lost)

        await sup.handle(.forceReconnectRequested)
        // Wait for backoff (0.01 s) + retry to run + transition back.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await assertStateEquals(sup, .lost,
                                "user_action_required loops back to .lost")
    }

    // MARK: - forceReconnectRequested resets wake accumulator (modal re-fire fix)

    func testForceReconnectClearsWakeAccumulator() async {
        // Reproduces the bug from real-device capture:
        //   1. Modal fires at 12 s (wakeAttemptStartedAtMs set to T0).
        //   2. User taps "다시 시도" → forceReconnectRequested.
        //   3. Without the fix, wakeAttemptStartedAtMs stayed at T0 →
        //      next wakeCycleStarted (within ms) computed elapsedMs ≈
        //      20 s → modal re-fires immediately, infinite loop.
        // The fix: forceReconnectRequested resets the accumulator so the
        // next wake cycle starts a fresh 12 s budget.
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let firstCount = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(firstCount, 1, "first prompt fires after threshold")

        // User taps retry. Should NOT immediately re-fire.
        await sup.handle(.forceReconnectRequested)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let immediateCount = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(immediateCount, 1,
                       "no immediate re-fire after force reconnect")

        // Only after the fresh 12 s window elapses should it fire again.
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let afterFreshWindow = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(afterFreshWindow, 2,
                       "prompt re-fires after fresh threshold elapses")
    }

    // MARK: - pairAttemptStarted resets wake state cleanly

    func testPairAttemptStartedPreservesAccumulatedWakeAttemptTime() async {
        // The bridge fires `.pairAttemptStarted` on every JS-triggered
        // retry of `assignWristRole`. Real users see this as a single
        // continuous "trying to connect" session — so we must NOT reset
        // `wakeAttemptStartedAtMs` between retries, otherwise the 12 s
        // threshold restarts indefinitely and the prompt never fires.
        let driverShouldNotBeCalled = expectation(description: "no driver call")
        driverShouldNotBeCalled.isInverted = true
        let (sup, obs) = await makeSupervisor(
            wakeStallSec: 0.05,
            reconnectDriver: { driverShouldNotBeCalled.fulfill() })
        await sup.handle(.attached)
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        // Cross the threshold; observer sees one prompt.
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let firstStallsCount = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(firstStallsCount, 1)

        // JS-side retry: pairAttemptStarted fires. Should NOT reset wake
        // accumulator (the user is still in the same session).
        await sup.handle(.pairAttemptStarted)
        await assertStateEquals(sup, .searching)

        // Reconnect driver was NOT scheduled by pairAttemptStarted.
        await fulfillment(of: [driverShouldNotBeCalled], timeout: 0.1)
    }

    func testReadinessProbeAckResetsWakeStateOnSuccess() async {
        // After a successful pair, wake state must clear so a *future*
        // user-initiated re-pair (force reconnect or 사진 찍기) can fire
        // the prompt again. NOTE: a drop-then-auto-reconnect path now
        // intentionally does NOT re-fire the prompt — wake events are
        // gated to `.searching`/`.connecting` so we don't false-alarm
        // during automatic recovery (post-stop save mode, RSSI drops,
        // etc.). The prompt fires again only when the user explicitly
        // re-enters the pair flow.
        let (sup, obs) = await makeSupervisor(wakeStallSec: 0.05)
        await sup.handle(.attached)
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let firstCount = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(firstCount, 1)

        // Recovery: scan_hit + readiness_probe_ack reaches bleReady.
        await sup.handle(.scanHit(rssi: -60))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await assertStateEquals(sup, .bleReady)

        // Drop + auto reconnect: wake events should NOT fire the prompt.
        await sup.handle(.unsolicitedDisconnect(error: "drop"))
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let afterAutoReconnect = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(afterAutoReconnect, 1,
                       "no false-alarm prompt during auto reconnect")

        // User explicitly re-enters the pair flow → wake state resets,
        // wake-stall threshold can fire again.
        await sup.handle(.forceReconnectRequested)
        await assertStateEquals(sup, .searching)
        await sup.handle(.wakeCycleStarted(strategy: "fast_scan"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        await sup.handle(.wakeCycleStarted(strategy: "targeted"))
        await Task.yield()
        let afterUserRetry = (await obs.snapshotWakeStalls()).count
        XCTAssertEqual(afterUserRetry, 2,
                       "prompt re-fires after user-initiated retry")
    }

    // MARK: - Detach is terminal

    func testDetachTransitionsToGiveUpAndCancelsReconnect() async {
        let driverFired = expectation(description: "should not be called")
        driverFired.isInverted = true
        let (sup, _) = await makeSupervisor(
            reconnectDriver: { driverFired.fulfill() })
        await sup.handle(.attached)
        await sup.handle(.scanHit(rssi: -65))
        await sup.handle(.readinessProbeAck(elapsedMs: 100))
        await sup.handle(.unsolicitedDisconnect(error: "x"))
        await sup.handle(.detached)
        await assertStateEquals(sup, .giveUp)
        await fulfillment(of: [driverFired], timeout: 0.1)
    }
}
