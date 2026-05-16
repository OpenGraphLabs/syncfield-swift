import Foundation

/// Process-global pub/sub for SDK-side wake cycle events. The static
/// wake methods on `Insta360BLEController` (`broadcastWake`,
/// `wake(serialLast6:)`) drive the actual BLE wake-up advertise loops.
/// Each `SEND` corresponds to one wake attempt that the supervisor's
/// wake-stall logic wants to count toward the 12 s prompt threshold.
///
/// We can't synthesize wake ticks from the bridge directly because
/// `Insta360Scanner.pair()` cancel/retry cycles would tear down a Task-
/// owned ticker before the 12 s window closes. The SDK's own wake calls,
/// on the other hand, keep firing as long as the SDK is still searching.
/// Subscribing here gives the supervisor a real-time picture of wake
/// activity regardless of pair attempt lifetime.
public enum Insta360WakeStrategy: String, Sendable {
    case broadcast
    case targeted
}

public enum Insta360WakeObserver {
    public typealias Listener = @Sendable (Insta360WakeStrategy, _ serialLast6: String?) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var listeners: [UUID: Listener] = [:]

    @discardableResult
    public static func subscribe(_ listener: @escaping Listener) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public static func unsubscribe(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeValue(forKey: id)
    }

    /// Called by the BLEController's static wake methods every time the
    /// SDK starts a new wake advertise window. Snapshot listeners under
    /// the lock, release, then dispatch — avoids holding the lock while
    /// listeners run.
    internal static func notify(_ strategy: Insta360WakeStrategy, serialLast6: String?) {
        lock.lock()
        let snapshot = Array(listeners.values)
        lock.unlock()
        for listener in snapshot {
            listener(strategy, serialLast6)
        }
    }
}
