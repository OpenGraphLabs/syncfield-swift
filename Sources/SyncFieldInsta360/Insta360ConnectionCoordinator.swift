import Foundation

/// Public-facing actor that owns supervisors, the RadioGate, and the
/// background-lifecycle hooks for all attached Insta360 cameras. The bridge
/// integrates with this single instance and routes RN events from the
/// supervisor observer.
public actor Insta360ConnectionCoordinator {
    public static let shared = Insta360ConnectionCoordinator()

    /// Observer event type — what the bridge emits to RN. Sendable so the
    /// supervisor's actor isolation is preserved across the boundary.
    public struct StateEvent: Sendable {
        public let bindingKey: String
        public let role: String?
        public let from: Insta360ConnectionState
        public let to: Insta360ConnectionState
        public let reason: String?
        public let health: Insta360ConnectionHealth
    }

    public struct WakeStallEvent: Sendable {
        public let bindingKey: String
        public let role: String?
        public let suggestedAction: Insta360WakeStallSuggestedAction
        public let health: Insta360ConnectionHealth
    }

    public typealias StateObserver = @Sendable (StateEvent) async -> Void
    public typealias WakeStallObserver = @Sendable (WakeStallEvent) async -> Void

    private var supervisors: [String: Insta360CameraSupervisor] = [:]
    private var stateObserver: StateObserver?
    private var wakeStallObserver: WakeStallObserver?

    /// `Insta360RadioGate` is configured with closures back to the
    /// coordinator so heartbeat-interval changes route to the right BLE
    /// controller. The bridge wires the controller closures during init.
    public private(set) lazy var radioGate: Insta360RadioGate = {
        Insta360RadioGate(
            config: .shared,
            setHeartbeatIntervalMs: { [weak self] key, ms in
                await self?.applyHeartbeatInterval(bindingKey: key, ms: ms)
            },
            emitSupervisorEvent: { [weak self] key, event in
                await self?.feed(bindingKey: key, event: event)
            })
    }()

    /// Bridge calls this after creating its `Insta360CameraStream` and
    /// completing the BLE pair. Coordinator attaches a supervisor, registers
    /// it with the RadioGate, and starts observing.
    public func attach(
        bindingKey: String,
        role: String?,
        reconnectDriver: Insta360CameraSupervisor.ReconnectDriver? = nil
    ) async -> Insta360CameraSupervisor {
        if let existing = supervisors[bindingKey] {
            return existing
        }
        let supervisor = Insta360CameraSupervisor(
            bindingKey: bindingKey,
            role: role,
            reconnectDriver: reconnectDriver)
        let routing = makeRoutingObserver(bindingKey: bindingKey, role: role)
        await supervisor.setObserver(routing)
        supervisors[bindingKey] = supervisor
        await radioGate.register(bindingKey: bindingKey)
        await supervisor.handle(.attached)
        InstaLog.log(.coord, "attached",
                     ["bindingKey": bindingKey,
                      "role": role ?? "?"])
        return supervisor
    }

    /// Build a routing observer that forwards a supervisor's transitions /
    /// wake-stalls to the coordinator's observer channels. Closure-based to
    /// sidestep the retain semantics of an `AnyObject` delegate.
    private func makeRoutingObserver(bindingKey: String, role: String?)
        -> Insta360CameraSupervisorObserver
    {
        Insta360CameraSupervisorObserver(
            didTransition: { [weak self] from, to, reason, health in
                guard let self = self else { return }
                let event = StateEvent(
                    bindingKey: bindingKey,
                    role: role,
                    from: from,
                    to: to,
                    reason: reason,
                    health: health)
                await self.emitStateTransition(event)
            },
            didEmitWakeStallRequiringUser: { [weak self] suggested, health in
                guard let self = self else { return }
                let event = WakeStallEvent(
                    bindingKey: bindingKey,
                    role: role,
                    suggestedAction: suggested,
                    health: health)
                await self.emitWakeStall(event)
            })
    }

    public func detach(bindingKey: String) async {
        guard let supervisor = supervisors[bindingKey] else { return }
        await supervisor.handle(.detached)
        await radioGate.unregister(bindingKey: bindingKey)
        // Release any held WiFi lease for this camera.
        if await radioGate.currentLeaseHolderBindingKey() == bindingKey {
            // Lease is implicit per binding; can't release without the lease
            // object. Caller must release explicitly via withWiFi.
            InstaLog.log(.coord, level: .warn, "detach_with_active_wifi_lease",
                         ["bindingKey": bindingKey])
        }
        supervisors.removeValue(forKey: bindingKey)
        InstaLog.log(.coord, "detached",
                     ["bindingKey": bindingKey])
    }

    public func detachAll() async {
        for key in supervisors.keys {
            await detach(bindingKey: key)
        }
    }

    /// Feed an external event into the supervisor's state machine. Used by
    /// the bridge to surface heartbeat ACK/miss, scan hits, disconnects.
    public func feed(bindingKey: String, event: Insta360SupervisorEvent) async {
        guard let supervisor = supervisors[bindingKey] else { return }
        await supervisor.handle(event)
    }

    public func forceReconnect(bindingKey: String) async {
        await feed(bindingKey: bindingKey, event: .forceReconnectRequested)
    }

    public func health(bindingKey: String) async -> Insta360ConnectionHealth? {
        guard let supervisor = supervisors[bindingKey] else { return nil }
        return await supervisor.snapshot()
    }

    public func allHealth() async -> [String: Insta360ConnectionHealth] {
        var out: [String: Insta360ConnectionHealth] = [:]
        for (key, supervisor) in supervisors {
            out[key] = await supervisor.snapshot()
        }
        return out
    }

    public func setStateObserver(_ observer: @escaping StateObserver) {
        stateObserver = observer
    }

    public func setWakeStallObserver(_ observer: @escaping WakeStallObserver) {
        wakeStallObserver = observer
    }

    public func isAttached(bindingKey: String) -> Bool {
        supervisors[bindingKey] != nil
    }

    public func attachedBindingKeys() -> [String] {
        Array(supervisors.keys)
    }

    // MARK: - Internal — wired via SupervisorObserver

    private func emitStateTransition(_ event: StateEvent) async {
        await stateObserver?(event)
    }

    private func emitWakeStall(_ event: WakeStallEvent) async {
        await wakeStallObserver?(event)
    }

    // MARK: - Heartbeat interval routing (bridge plugs in real implementation)

    public typealias HeartbeatIntervalSetter =
        @Sendable (_ bindingKey: String, _ intervalMs: UInt64?) async -> Void

    private var heartbeatIntervalSetter: HeartbeatIntervalSetter?

    public func setHeartbeatIntervalSetter(_ setter: @escaping HeartbeatIntervalSetter) {
        heartbeatIntervalSetter = setter
    }

    private func applyHeartbeatInterval(bindingKey: String, ms: UInt64?) async {
        if let setter = heartbeatIntervalSetter {
            await setter(bindingKey, ms)
        }
    }

    public init() {}
}

