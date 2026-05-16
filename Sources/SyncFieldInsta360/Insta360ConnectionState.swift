import Foundation

/// State machine emitted by `Insta360CameraSupervisor`. The transitions are
/// documented in `cheeky-baking-allen.md` (Per-camera State Machine table).
///
/// - Note: Sub-states for phone-auth pairing are surfaced as `.connecting`
///   with a refined `Insta360ConnectionHealth.lastError` payload rather than
///   their own case — keeps the surface stable for RN consumers.
public enum Insta360ConnectionState: String, Sendable, Equatable {
    /// Initial state — no `attach()` has been called for this binding key.
    case idle

    /// BLE scan window open, looking for an advertisement matching this UUID.
    case searching

    /// Advertisement found, BLE connect in progress (CoreBluetooth + readiness
    /// probe `getCurrentCaptureStatus`).
    case connecting

    /// BLE connected, command channel ACK'd at least once, heartbeat firing.
    case bleReady

    /// Connected but degraded: RSSI < threshold or recent heartbeat misses.
    /// May recover without a full reconnect.
    case bleDegraded

    /// `RadioGate.acquireWiFi` granted. AP-bound camera; heartbeat paused.
    /// Other supervised cameras are on slow heartbeat for the lease duration.
    case wifiBound

    /// App backgrounded with no active recording. CoreBluetooth link retained
    /// by iOS, heartbeat paused. Recovery on foreground entry.
    case bleSuspended

    /// Unsolicited disconnect; `ReconnectPolicy` backoff schedule running.
    case reconnecting

    /// Persistent classifier fired (no advertisement for N scan windows,
    /// or hard CoreBluetooth error). Requires user action (power button,
    /// undock) or explicit `forceReconnect`.
    case lost

    /// `detach()` called or session ended. Terminal — supervisor will not
    /// reconnect.
    case giveUp

    /// Whether the supervisor accepts BLE commands while in this state.
    /// Used by callers (Bridge, Collector) to decide fast-fail vs await.
    public var acceptsCommands: Bool {
        switch self {
        case .bleReady, .bleDegraded, .wifiBound: return true
        case .idle, .searching, .connecting, .bleSuspended,
             .reconnecting, .lost, .giveUp: return false
        }
    }

    /// Whether transition to this state is terminal (no further automatic
    /// recovery without explicit user action).
    public var isTerminal: Bool {
        switch self {
        case .lost, .giveUp: return true
        default: return false
        }
    }
}
