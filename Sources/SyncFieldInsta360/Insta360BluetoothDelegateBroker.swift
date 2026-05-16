import Foundation

#if canImport(INSCameraServiceSDK)
import INSCameraServiceSDK

/// Process-wide multiplexer for `INSBluetoothManagerDelegate` callbacks.
///
/// The SDK's `INSBluetoothManager` exposes a single weak `delegate` property
/// — last setter wins. With two `Insta360BLEController` instances (one per
/// wrist) the late-initialized controller silently steals the delegate slot
/// from the earlier one, so the earlier controller's
/// `device(_:didDisconnectWithError:)` never fires. The downstream symptom
/// observed in S3 logs: a camera physically goes out of range, CoreBluetooth
/// surfaces the disconnect on the wrong controller, the supervisor for the
/// affected role never sees `.unsolicitedDisconnect`, and the supervisor sits
/// in `.bleDegraded` accumulating `heartbeat_miss` indefinitely instead of
/// scheduling reconnect.
///
/// The broker fixes routing by:
///   1. Claiming the manager's delegate slot exactly once (idempotent),
///   2. Fanning every callback out to every registered controller,
///   3. Letting each controller's existing `isOurDevice` UUID check gate
///      side effects so only the affected controller acts.
///
/// Weak-set storage means controllers torn down by `unpairWristCamera` drop
/// out automatically; no explicit unregister required, though we keep one as
/// belt-and-suspenders.
public final class Insta360BluetoothDelegateBroker: NSObject, INSBluetoothManagerDelegate, @unchecked Sendable {
    public static let shared = Insta360BluetoothDelegateBroker()

    private let lock = NSLock()
    private let listeners = NSHashTable<Insta360BLEController>.weakObjects()
    private weak var installedManager: INSBluetoothManager?

    private override init() { super.init() }

    /// Register a controller to receive `INSBluetoothManagerDelegate`
    /// callbacks for every device. The first registration also claims the
    /// manager's delegate slot for the broker so subsequent SDK delegate
    /// dispatch routes through `self`.
    public func register(_ controller: Insta360BLEController,
                         on manager: INSBluetoothManager) {
        lock.lock()
        listeners.add(controller)
        let shouldInstall = (installedManager !== manager)
        if shouldInstall {
            installedManager = manager
        }
        lock.unlock()
        // Set delegate outside the lock — `delegate` is `weak`, but assigning
        // it may trigger ObjC side effects we don't want to hold the lock for.
        // Re-set on every new manager identity in case the SDK re-creates
        // its manager (rare, but cheap).
        if shouldInstall {
            manager.delegate = self
        }
    }

    /// Explicit unregister. Safe to call before deinit; weak-set would drop
    /// the entry anyway when ARC frees the controller. Useful in tests that
    /// reuse a controller across cases.
    public func unregister(_ controller: Insta360BLEController) {
        lock.lock()
        listeners.remove(controller)
        lock.unlock()
    }

    /// Number of currently registered controllers. Exposed for tests.
    public var listenerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return listeners.allObjects.count
    }

    private func snapshot() -> [Insta360BLEController] {
        lock.lock(); defer { lock.unlock() }
        return listeners.allObjects
    }

    // MARK: - INSBluetoothManagerDelegate

    public func deviceDidConnected(_ device: INSBluetoothDevice) {
        for listener in snapshot() {
            listener.bluetoothDelegate_deviceDidConnected(device)
        }
    }

    public func device(_ device: INSBluetoothDevice,
                       didDisconnectWithError error: Error?) {
        for listener in snapshot() {
            listener.bluetoothDelegate_device(device,
                                               didDisconnectWithError: error)
        }
    }
}

#endif
