import Foundation

/// Closure-based event sink for `Insta360CameraSupervisor` outputs. The
/// coordinator wires a single bundle of closures to forward transitions and
/// wake-stall events to RN. Closures-instead-of-protocol avoids the retain
/// dance that an `AnyObject` observer would force on the supervisor.
public struct Insta360CameraSupervisorObserver: Sendable {
    public var didTransition:
        @Sendable (_ from: Insta360ConnectionState,
                   _ to: Insta360ConnectionState,
                   _ reason: String?,
                   _ health: Insta360ConnectionHealth) async -> Void
    public var didEmitWakeStallRequiringUser:
        @Sendable (_ suggested: Insta360WakeStallSuggestedAction,
                   _ health: Insta360ConnectionHealth) async -> Void

    public init(
        didTransition: @escaping @Sendable (_ from: Insta360ConnectionState,
                                            _ to: Insta360ConnectionState,
                                            _ reason: String?,
                                            _ health: Insta360ConnectionHealth) async -> Void
            = { _, _, _, _ in },
        didEmitWakeStallRequiringUser:
            @escaping @Sendable (_ suggested: Insta360WakeStallSuggestedAction,
                                 _ health: Insta360ConnectionHealth) async -> Void
            = { _, _ in }
    ) {
        self.didTransition = didTransition
        self.didEmitWakeStallRequiringUser = didEmitWakeStallRequiringUser
    }
}

public enum Insta360WakeStallSuggestedAction: String, Sendable {
    case powerButton
    case removeFromDock
}

/// External input events the supervisor consumes. Keeping the surface
/// explicit (rather than wiring CoreBluetooth/INSCameraServiceSDK callbacks
/// directly into the supervisor) means we can drive the state machine from a
/// unit test with zero hardware.
public enum Insta360SupervisorEvent: Sendable, Equatable {
    case attached
    /// Bridge tells the supervisor "a new pair attempt is about to start"
    /// so wake-stall counters (`wakeAttemptStartedAtMs`, prompt emitted,
    /// empty scan windows) reset cleanly between retries without firing
    /// the reconnect Task. Distinct from `.forceReconnectRequested` which
    /// is for explicit recovery from `lost`.
    case pairAttemptStarted
    /// Recording-readiness probe failed AFTER a nominal BLE pair (the
    /// camera is BLE-responsive but its command channel reports
    /// "camera is not powered on" — typically ActionPod is off while
    /// docked, or the half-awake state documented in `mobile/CLAUDE.md`).
    /// Triggers an IMMEDIATE wake-stall prompt to RN bypassing the 12 s
    /// threshold so the user gets actionable guidance at the device-
    /// connection screen (where the phone is still in hand) rather than
    /// only at record-start time (where the phone is head-mounted).
    case recordingReadinessFailed
    case scanWindowOpened(durationMs: Int)
    case scanHit(rssi: Int?)
    case scanWindowClosedNoHit
    case wakeCycleStarted(strategy: String)
    case readinessProbeStarted
    case readinessProbeAck(elapsedMs: Int)
    case readinessProbeFailed(error: String)
    case connectFailed(error: String)
    case heartbeatAck(rssi: Int?)
    case heartbeatMiss
    case rssiSample(Int)
    case unsolicitedDisconnect(error: String?)
    case wifiAcquired
    case wifiReleased
    case backgroundEntered(recordingActive: Bool)
    case foregroundEntered
    case forceReconnectRequested
    case dockPolled(status: Insta360DockStatus)
    case batteryPolled(percent: Int?, charging: Bool?)
    case detached
}

/// Per-camera state-machine actor. Holds `Insta360ConnectionHealth`, drives
/// transitions in response to `Insta360SupervisorEvent` inputs, emits to its
/// observer, and (when configured) schedules a reconnect Task on
/// unsolicited disconnect.
public actor Insta360CameraSupervisor {
    public let bindingKey: String
    public let role: String?
    public let policy: Insta360ReconnectPolicy
    public let config: Insta360CoordinatorConfig

    private(set) public var health: Insta360ConnectionHealth
    private var observer: Insta360CameraSupervisorObserver?

    // Reconnect ramp + persistent classifier inputs
    private var reconnectAttempt: Int = 0
    private var consecutiveEmptyScanWindows: Int = 0
    private var wakeAttemptStartedAtMs: UInt64?
    private var wakeStallPromptEmitted: Bool = false
    private var reconnectTask: Task<Void, Never>?
    /// Timestamp of the most recently processed `.unsolicitedDisconnect`
    /// event. Set at the FIRST statement of the handler (before any
    /// `await`) so duplicate events queued behind the first one — which
    /// only see the actor again after `transition`'s observer await
    /// yields — observe the marker and short-circuit. Earlier attempt
    /// to gate on `lastReconnectScheduleAtMs` failed because that field
    /// is only set inside `scheduleReconnect()`, which runs AFTER the
    /// observer await, so the duplicate slipped past with a nil marker.
    private var lastUnsolicitedDisconnectAtMs: UInt64?

    /// Provider for the supervisor's own reconnect Task. Real coordinator
    /// passes a closure that invokes BLE scan + connect; tests pass a stub.
    public typealias ReconnectDriver = @Sendable () async throws -> Void
    private let reconnectDriver: ReconnectDriver?

    public init(
        bindingKey: String,
        role: String?,
        policy: Insta360ReconnectPolicy = Insta360ReconnectPolicy(),
        config: Insta360CoordinatorConfig = .shared,
        reconnectDriver: ReconnectDriver? = nil
    ) {
        self.bindingKey = bindingKey
        self.role = role
        self.policy = policy
        self.config = config
        self.reconnectDriver = reconnectDriver
        self.health = Insta360ConnectionHealth(bindingKey: bindingKey, role: role)
    }

    public func setObserver(_ observer: Insta360CameraSupervisorObserver?) {
        self.observer = observer
    }

    /// Single funnel for all external events. State transitions, side-effects,
    /// and observer notification flow from here.
    public func handle(_ event: Insta360SupervisorEvent) async {
        InstaLog.log(.sup, role: role, level: .debug, "event_received",
                     ["event": String(describing: event)])
        switch event {
        case .attached:
            await transition(to: .searching, reason: "attached")

        case .recordingReadinessFailed:
            // Treat exactly like the 12 s wake-stall threshold being
            // crossed: emit an immediate wake-stall prompt event so the
            // globally-mounted RN modal surfaces. Then reset wake state
            // so any subsequent retry can re-arm without inheriting the
            // already-emitted flag.
            let suggested: Insta360WakeStallSuggestedAction =
                health.dockHint == .docked ? .removeFromDock : .powerButton
            InstaLog.log(.wake, role: role, level: .state,
                         "wake_user_prompt_emitted",
                         ["source": "recording_readiness_failed",
                          "suggested_action": suggested.rawValue])
            if let observer = observer {
                await observer.didEmitWakeStallRequiringUser(suggested, health)
            }
            wakeAttemptStartedAtMs = nil
            wakeStallPromptEmitted = false
            consecutiveEmptyScanWindows = 0
            // Transition to `.lost` so the supervisor isn't stuck in
            // `.searching` accumulating wake events forever. Lost is
            // explicitly user-recoverable: forceReconnect (modal "다시
            // 시도") and a fresh `assignWristRole` (user re-taps 사진
            // 찍기) both transition back to `.searching`.
            if !health.state.isTerminal {
                await transition(to: .lost,
                                 reason: "recording_readiness_failed")
            }

        case .pairAttemptStarted:
            // Reset scan-window counter (each pair attempt is a fresh
            // discovery effort). But preserve `wakeAttemptStartedAtMs` if
            // we're already accumulating: JS-triggered retries during a
            // single user-perceived "trying to connect" session would
            // otherwise restart the 12 s clock indefinitely. The clock
            // resets only when the supervisor reaches a healthy state
            // (handled in `.readinessProbeAck` → bleReady path) or via an
            // explicit `.forceReconnectRequested`.
            consecutiveEmptyScanWindows = 0
            // Allow recovery from `.lost` (user-recoverable terminal):
            // user just tapped 사진 찍기 / 다음 again to retry. Only
            // `.giveUp` is permanently terminal (explicit detach).
            if health.state != .searching && health.state != .giveUp {
                await transition(to: .searching, reason: "pair_attempt_started")
            }
            InstaLog.log(.sup, role: role, "pair_attempt_started",
                         ["wake_accumulating": wakeAttemptStartedAtMs != nil])

        case .scanWindowOpened(let durationMs):
            InstaLog.log(.sup, role: role, "scan_window_opened",
                         ["duration_ms": durationMs])

        case .scanHit(let rssi):
            consecutiveEmptyScanWindows = 0
            health.rssi = rssi
            health.lastSeenAtMs = nowMs()
            InstaLog.log(.sup, role: role, "scan_hit",
                         ["rssi": rssi as Any])
            await transition(to: .connecting, reason: "scan_hit")

        case .scanWindowClosedNoHit:
            consecutiveEmptyScanWindows += 1
            InstaLog.log(.sup, role: role, "scan_window_closed_no_hit",
                         ["consecutive": consecutiveEmptyScanWindows])
            await checkPersistentClassifier()

        case .wakeCycleStarted(let strategy):
            // Wake events count toward the wake-stall threshold ONLY
            // when the supervisor is actively trying to discover/connect
            // a camera (= the user is in the pair flow). During every
            // other state — `.reconnecting` (auto-recovery after a drop,
            // e.g. mid-recording or post-stop save mode), `.bleReady`
            // (steady state), `.wifiBound` (collect), `.bleSuspended`
            // (background) — the SDK's wake retries are part of the
            // bridge's automatic recovery and should NOT surface a
            // "please power on" modal to the user. Filtering here also
            // covers `.lost`/`.giveUp` so the modal-storm bug from the
            // previous incident stays fixed.
            switch health.state {
            case .searching, .connecting:
                break   // only states where wake-stall is meaningful
            default:
                return
            }
            if wakeAttemptStartedAtMs == nil {
                wakeAttemptStartedAtMs = nowMs()
            }
            InstaLog.log(.wake, role: role, "wake_strategy_started",
                         ["strategy": strategy])
            await checkWakeStall()

        case .readinessProbeStarted:
            InstaLog.log(.sup, role: role, "readiness_probe_started")

        case .readinessProbeAck(let elapsedMs):
            health.lastCommandSuccessAtMs = nowMs()
            wakeAttemptStartedAtMs = nil
            wakeStallPromptEmitted = false
            InstaLog.log(.sup, role: role, "readiness_probe_ack",
                         ["elapsed_ms": elapsedMs])
            await transition(to: .bleReady, reason: "readiness_probe_ack")

        case .readinessProbeFailed(let error):
            health.lastError = error
            health.lastErrorAtMs = nowMs()
            InstaLog.log(.sup, role: role, level: .warn, "readiness_probe_failed",
                         ["error": error])

        case .connectFailed(let error):
            health.lastError = error
            health.lastErrorAtMs = nowMs()
            health.connectAttemptsThisSession += 1
            InstaLog.log(.sup, role: role, level: .warn, "connect_failed",
                         ["error": error])

        case .heartbeatAck(let rssi):
            health.consecutiveHeartbeatMisses = 0
            if let rssi { health.rssi = rssi }
            health.lastCommandSuccessAtMs = nowMs()
            health.lastSeenAtMs = nowMs()
            // .debug so 2 s heartbeat doesn't drown the scenario tape;
            // toggle scenario mode to surface this in dev builds.
            InstaLog.log(.sup, role: role, level: .debug, "heartbeat_ack",
                         ["rssi": rssi as Any])
            if health.state == .bleDegraded {
                await transition(to: .bleReady, reason: "heartbeat_recovered")
            }

        case .heartbeatMiss:
            health.consecutiveHeartbeatMisses += 1
            InstaLog.log(.sup, role: role, level: .warn, "heartbeat_miss",
                         ["consecutive": health.consecutiveHeartbeatMisses])
            if health.consecutiveHeartbeatMisses >= 2 && health.state == .bleReady {
                await transition(to: .bleDegraded, reason: "heartbeat_miss")
            }

        case .rssiSample(let rssi):
            health.rssi = rssi
            if rssi < -85 && health.state == .bleReady {
                await transition(to: .bleDegraded, reason: "rssi<-85")
            }

        case .unsolicitedDisconnect(let error):
            let now = nowMs()
            // Debounce SDK-side duplicate disconnect fires. The SDK
            // surfaces the same drop through multiple paths within
            // milliseconds (CoreBluetooth peripheral disconnect +
            // INSCameraManager internal cleanup + `markConnectionStale`
            // cascade). Each fire enqueues a Task → handle(.unsolicited
            // Disconnect), and `transition`'s observer `await` yields the
            // actor between the first event setting state=.reconnecting
            // and calling `scheduleReconnect()`, so the second event
            // slips through any state-only gate. Set this marker BEFORE
            // any `await` so duplicates queued behind the first see it.
            if let last = lastUnsolicitedDisconnectAtMs, now - last < 500 {
                InstaLog.log(.sup, role: role, level: .debug,
                             "unsolicited_disconnect_debounced",
                             ["since_last_ms": now - last])
                return
            }
            lastUnsolicitedDisconnectAtMs = now
            health.lastError = error
            health.lastErrorAtMs = now
            health.consecutiveHeartbeatMisses = 0
            InstaLog.log(.ble, role: role, level: .warn, "didDisconnectWithError",
                         ["error": error as Any])
            guard config.autoReconnectEnabled else {
                await transition(to: .lost, reason: "auto_reconnect_disabled")
                return
            }
            await transition(to: .reconnecting, reason: "unsolicited_disconnect")
            scheduleReconnect()

        case .wifiAcquired:
            health.wifiInFlight = true
            await transition(to: .wifiBound, reason: "radio_gate_acquired")

        case .wifiReleased:
            health.wifiInFlight = false
            await transition(to: .bleReady, reason: "radio_gate_released")

        case .backgroundEntered(let recordingActive):
            InstaLog.log(.bg, role: role, "did_enter_background",
                         ["recording_active": recordingActive])
            if !recordingActive && config.backgroundBLEEnabled {
                await transition(to: .bleSuspended, reason: "background_idle")
            }

        case .foregroundEntered:
            InstaLog.log(.bg, role: role, "will_enter_foreground")
            if health.state == .bleSuspended {
                await transition(to: .searching, reason: "foreground_resume")
                // Kick the reconnect driver so the bridge runs
                // `refreshConnection`. If iOS kept the GATT link alive
                // (bluetooth-central background mode), this is a fast
                // command-channel probe → synthetic scanHit + readiness
                // → bleReady. If iOS dropped the peripheral while we were
                // suspended, the driver falls back to its wake+repair
                // path and the backoff schedule takes over. Without
                // this call the supervisor would sit in `.searching`
                // indefinitely with nothing scheduling work.
                scheduleReconnect()
            }

        case .forceReconnectRequested:
            InstaLog.log(.sup, role: role, "force_reconnect_requested")
            // User explicitly acknowledged the wake-stall prompt and is
            // retrying. Reset the FULL wake accounting so the next 12 s
            // window starts fresh from the user's action — otherwise the
            // previously-accumulated elapsedMs (often 20+ s) would
            // re-cross the threshold within milliseconds of the tap, and
            // the modal would re-appear immediately.
            wakeAttemptStartedAtMs = nil
            wakeStallPromptEmitted = false
            consecutiveEmptyScanWindows = 0
            await transition(to: .searching, reason: "force_reconnect")
            scheduleReconnect()

        case .dockPolled(let status):
            health.dockHint = status
            health.dockHintLastUpdatedAtMs = nowMs()

        case .batteryPolled(let percent, let charging):
            health.batteryPercent = percent
            health.batteryCharging = charging

        case .detached:
            reconnectTask?.cancel()
            reconnectTask = nil
            await transition(to: .giveUp, reason: "detached")
        }
    }

    /// Synchronous health snapshot for the coordinator's `health(bindingKey:)`.
    public func snapshot() -> Insta360ConnectionHealth {
        health
    }

    // MARK: - Internals

    private func transition(to next: Insta360ConnectionState, reason: String?) async {
        let previous = health.state
        guard previous != next else { return }
        health.state = next
        InstaLog.state(.sup, role: role,
                       from: previous.rawValue, to: next.rawValue, reason: reason)
        // Reset reconnect bookkeeping on any healthy state.
        if next == .bleReady || next == .wifiBound {
            reconnectAttempt = 0
            lastUnsolicitedDisconnectAtMs = nil
        }
        if let observer = observer {
            await observer.didTransition(previous, next, reason, health)
        }
    }

    private func checkPersistentClassifier() async {
        let msSinceLastAdvert: UInt64? = health.lastSeenAtMs.map { lastSeen in
            let now = nowMs()
            return now > lastSeen ? now - lastSeen : 0
        }
        if Insta360ReconnectPolicy.shouldClassifyAsLost(
            consecutiveScanWindowsWithoutAdvert: consecutiveEmptyScanWindows,
            lastErrorDescription: health.lastError,
            msSinceLastAdvertisement: msSinceLastAdvert,
            config: config)
        {
            InstaLog.log(.sup, role: role, level: .warn,
                         "persistent_classifier_fired",
                         ["consecutive_empty_windows": consecutiveEmptyScanWindows])
            await transition(to: .lost, reason: "persistent_classifier")
        }
    }

    private func checkWakeStall() async {
        guard config.wakeUserPromptEnabled,
              !wakeStallPromptEmitted,
              let started = wakeAttemptStartedAtMs else { return }
        let elapsedMs = nowMs() - started
        let thresholdMs = UInt64(config.wakeStallThresholdSeconds * 1_000)
        if elapsedMs >= thresholdMs {
            wakeStallPromptEmitted = true
            let suggested: Insta360WakeStallSuggestedAction =
                health.dockHint == .docked ? .removeFromDock : .powerButton
            InstaLog.log(.wake, role: role, level: .state,
                         "wake_user_prompt_emitted",
                         ["elapsed_ms": elapsedMs,
                          "suggested_action": suggested.rawValue])
            if let observer = observer {
                await observer.didEmitWakeStallRequiringUser(suggested, health)
            }
        }
    }

    private func scheduleReconnect() {
        guard let driver = reconnectDriver else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delaySeconds = policy.backoffSeconds(forAttempt: attempt)
        InstaLog.log(.sup, role: role, "reconnect_scheduled",
                     ["attempt": attempt,
                      "backoff_ms": Int(delaySeconds * 1_000)])
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            await self.runReconnectAttempt(attempt: attempt, driver: driver)
        }
    }

    private func runReconnectAttempt(attempt: Int, driver: ReconnectDriver) async {
        InstaLog.log(.sup, role: role, "reconnect_attempt",
                     ["attempt": attempt])
        do {
            try await driver()
            InstaLog.log(.sup, role: role, "reconnect_success",
                         ["attempt": attempt])
            // Successful reconnect signals will arrive via subsequent events
            // (scanHit → readinessProbeAck → bleReady). No state change here.
        } catch is CancellationError {
            // We were superseded by a fresh scheduleReconnect (typically
            // because a stale-link cascade fired another disconnect). The
            // newer task already owns the ramp — don't compound by
            // re-scheduling again from this catch path, which would
            // double the attempt counter and inflate the next backoff.
            InstaLog.log(.sup, role: role, level: .debug,
                         "reconnect_superseded",
                         ["attempt": attempt])
            return
        } catch {
            let description = String(describing: error)
            health.lastError = description
            health.lastErrorAtMs = nowMs()
            health.connectAttemptsThisSession += 1
            InstaLog.log(.sup, role: role, level: .warn, "reconnect_failed",
                         ["attempt": attempt, "error": description])
            // Driver signalled the failure can't be auto-recovered — only
            // a user action via the device-discovery UI will progress.
            // Transition back to `.lost` and STOP the backoff loop so we
            // don't drain CPU / actor queue spamming the same failure.
            if description.contains("user_action_required") {
                if !health.state.isTerminal {
                    await transition(to: .lost,
                                     reason: "reconnect_user_action_required")
                }
                return
            }
            // Otherwise, keep trying within the policy ceiling.
            if attempt < policy.maxAttempts && !health.state.isTerminal {
                scheduleReconnect()
            }
        }
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }
}
