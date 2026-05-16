import Foundation

/// Token returned by `Insta360RadioGate.acquireWiFi`. The caller is required
/// to release the same lease back to the gate when finished — `withWiFi(_:)`
/// is the safe wrapper.
public struct Insta360RadioLease: Sendable, Equatable {
    public let bindingKey: String
    let id: UUID
    init(bindingKey: String) {
        self.bindingKey = bindingKey
        self.id = UUID()
    }
}

/// Serializes Wi-Fi / BLE radio access across multiple supervised cameras.
/// Goals:
///
/// 1. Only one camera AP can be active at a time on the iPhone — second
///    `acquireWiFi` blocks until the first releases.
/// 2. While a Wi-Fi session is in flight, other supervised cameras drop to
///    `radioGateSlowHeartbeatIntervalMs` (default 8 s) so the BLE/Wi-Fi
///    chipset doesn't starve them.
/// 3. AP-bound camera's heartbeat is fully suspended for the lease duration
///    (re-enabled on release).
///
/// The gate emits structured logs and notifies the coordinator so individual
/// supervisors update state.
public actor Insta360RadioGate {
    public typealias HeartbeatSetter = @Sendable (String, UInt64?) async -> Void
    public typealias SupervisorEventEmitter =
        @Sendable (String, Insta360SupervisorEvent) async -> Void

    private struct Holder: Sendable {
        let lease: Insta360RadioLease
        let acquiredAtMs: UInt64
    }

    private var currentHolder: Holder?
    private var waitingContinuations: [(bindingKey: String,
                                        continuation: CheckedContinuation<Insta360RadioLease, Never>)] = []

    /// All currently supervised cameras — used to apply slow-heartbeat mode
    /// to non-holders. Keys are binding keys; values are role hints for logs.
    private var supervisedBindingKeys: Set<String> = []

    private let setHeartbeatIntervalMs: HeartbeatSetter?
    private let emitSupervisorEvent: SupervisorEventEmitter?
    private let config: Insta360CoordinatorConfig

    public init(
        config: Insta360CoordinatorConfig = .shared,
        setHeartbeatIntervalMs: HeartbeatSetter? = nil,
        emitSupervisorEvent: SupervisorEventEmitter? = nil
    ) {
        self.config = config
        self.setHeartbeatIntervalMs = setHeartbeatIntervalMs
        self.emitSupervisorEvent = emitSupervisorEvent
    }

    public func register(bindingKey: String) {
        supervisedBindingKeys.insert(bindingKey)
    }

    public func unregister(bindingKey: String) {
        supervisedBindingKeys.remove(bindingKey)
    }

    public func currentLeaseHolderBindingKey() -> String? {
        currentHolder?.lease.bindingKey
    }

    /// Acquire exclusive WiFi access for `bindingKey`. Blocks until any
    /// existing lease is released. The returned lease must be released via
    /// `releaseWiFi(_:)`.
    public func acquireWiFi(bindingKey: String) async -> Insta360RadioLease {
        InstaLog.log(.radio, "acquireWiFi_requested",
                     ["bindingKey": bindingKey])
        let requestedAt = Date()
        guard config.radioGateEnabled else {
            // Pass-through when gate disabled: no slow-mode, no serialization.
            let lease = Insta360RadioLease(bindingKey: bindingKey)
            currentHolder = Holder(lease: lease,
                                   acquiredAtMs: UInt64(requestedAt.timeIntervalSince1970 * 1_000))
            InstaLog.log(.radio, level: .warn, "acquireWiFi_granted_passthrough",
                         ["bindingKey": bindingKey])
            return lease
        }
        if currentHolder == nil {
            return await grantWiFi(to: bindingKey, waitedMs: 0)
        }
        InstaLog.log(.radio, "acquireWiFi_blocked",
                     ["bindingKey": bindingKey,
                      "reason": "another_camera_active",
                      "holder": currentHolder!.lease.bindingKey])
        return await withCheckedContinuation { (cont: CheckedContinuation<Insta360RadioLease, Never>) in
            waitingContinuations.append((bindingKey, cont))
        }
    }

    public func releaseWiFi(_ lease: Insta360RadioLease) async {
        guard let holder = currentHolder, holder.lease == lease else {
            InstaLog.log(.radio, level: .warn, "releaseWiFi_unknown_lease",
                         ["bindingKey": lease.bindingKey])
            return
        }
        let durationMs = nowMs() - holder.acquiredAtMs
        currentHolder = nil
        InstaLog.log(.radio, "releaseWiFi",
                     ["bindingKey": lease.bindingKey,
                      "duration_ms": durationMs])
        // Restore everyone to normal heartbeat
        if let setHB = setHeartbeatIntervalMs {
            for key in supervisedBindingKeys {
                await setHB(key, config.heartbeatIntervalMs)
            }
        }
        if let emit = emitSupervisorEvent {
            await emit(lease.bindingKey, .wifiReleased)
        }
        InstaLog.log(.radio, "slow_mode_released")
        // Grant the next waiter, if any.
        if !waitingContinuations.isEmpty {
            let next = waitingContinuations.removeFirst()
            let granted = await grantWiFi(to: next.bindingKey,
                                          waitedMs: durationMs)
            next.continuation.resume(returning: granted)
        }
    }

    /// Convenience wrapper that guarantees lease release even on throw.
    public func withWiFi<T>(bindingKey: String,
                            _ body: (Insta360RadioLease) async throws -> T) async rethrows -> T {
        let lease = await acquireWiFi(bindingKey: bindingKey)
        do {
            let result = try await body(lease)
            await releaseWiFi(lease)
            return result
        } catch {
            await releaseWiFi(lease)
            throw error
        }
    }

    // MARK: - Internals

    private func grantWiFi(to bindingKey: String,
                           waitedMs: UInt64) async -> Insta360RadioLease {
        let lease = Insta360RadioLease(bindingKey: bindingKey)
        currentHolder = Holder(lease: lease, acquiredAtMs: nowMs())
        InstaLog.log(.radio, level: .state, "acquireWiFi_granted",
                     ["bindingKey": bindingKey,
                      "wait_ms": waitedMs])

        // Slow-mode everyone else, suspend heartbeat for the holder.
        if let setHB = setHeartbeatIntervalMs {
            for key in supervisedBindingKeys where key != bindingKey {
                await setHB(key, config.radioGateSlowHeartbeatIntervalMs)
            }
            // nil interval = suspended
            await setHB(bindingKey, nil)
        }
        if !supervisedBindingKeys.isEmpty {
            let others = supervisedBindingKeys.filter { $0 != bindingKey }
            InstaLog.log(.radio, "slow_mode_engaged",
                         ["other_cameras": Array(others)])
        }
        if let emit = emitSupervisorEvent {
            await emit(bindingKey, .wifiAcquired)
        }
        return lease
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }
}
