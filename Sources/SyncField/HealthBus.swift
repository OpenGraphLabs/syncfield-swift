// Sources/SyncField/HealthBus.swift
import Foundation

/// In-process event bus for stream lifecycle signals.
/// Subscribers are not back-pressured; `bufferingPolicy: .bufferingNewest(64)`
/// drops oldest events when a slow subscriber falls behind.
public final class HealthBus: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<HealthEvent>.Continuation] = [:]
    private let lock = NSLock()

    public init() {}

    public func subscribe() -> AsyncStream<HealthEvent> {
        AsyncStream(HealthEvent.self, bufferingPolicy: .bufferingNewest(64)) { cont in
            let id = UUID()
            lock.lock(); continuations[id] = cont; lock.unlock()

            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations.removeValue(forKey: id); self.lock.unlock()
            }
        }
    }

    public func publish(_ event: HealthEvent) async {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for cont in targets { cont.yield(event) }
    }

    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for cont in targets { cont.finish() }
    }
}
