import Foundation

/// Per-camera health snapshot exposed by `Insta360ConnectionCoordinator.health`
/// and the periodic `syncfield:insta360HealthSnapshot` event. Surface is
/// deliberately RN-serializable (only scalars and well-known enums) so the
/// bridge can convert it with no field-by-field translation.
public struct Insta360ConnectionHealth: Sendable, Equatable {
    public var bindingKey: String
    public var role: String?
    public var state: Insta360ConnectionState

    // Liveness
    public var rssi: Int?
    public var lastSeenAtMs: UInt64?
    public var lastCommandSuccessAtMs: UInt64?
    public var consecutiveHeartbeatMisses: Int

    // Connect history
    public var connectAttemptsThisSession: Int
    public var lastError: String?
    public var lastErrorAtMs: UInt64?

    // Device hints (best-effort, can be nil)
    public var dockHint: Insta360DockStatus
    public var dockHintLastUpdatedAtMs: UInt64?
    public var batteryPercent: Int?
    public var batteryCharging: Bool?

    // Activity
    public var wifiInFlight: Bool

    public init(
        bindingKey: String,
        role: String? = nil,
        state: Insta360ConnectionState = .idle,
        rssi: Int? = nil,
        lastSeenAtMs: UInt64? = nil,
        lastCommandSuccessAtMs: UInt64? = nil,
        consecutiveHeartbeatMisses: Int = 0,
        connectAttemptsThisSession: Int = 0,
        lastError: String? = nil,
        lastErrorAtMs: UInt64? = nil,
        dockHint: Insta360DockStatus = .unknown,
        dockHintLastUpdatedAtMs: UInt64? = nil,
        batteryPercent: Int? = nil,
        batteryCharging: Bool? = nil,
        wifiInFlight: Bool = false
    ) {
        self.bindingKey = bindingKey
        self.role = role
        self.state = state
        self.rssi = rssi
        self.lastSeenAtMs = lastSeenAtMs
        self.lastCommandSuccessAtMs = lastCommandSuccessAtMs
        self.consecutiveHeartbeatMisses = consecutiveHeartbeatMisses
        self.connectAttemptsThisSession = connectAttemptsThisSession
        self.lastError = lastError
        self.lastErrorAtMs = lastErrorAtMs
        self.dockHint = dockHint
        self.dockHintLastUpdatedAtMs = dockHintLastUpdatedAtMs
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.wifiInFlight = wifiInFlight
    }

    /// RN-friendly dictionary; safe to send across the bridge directly.
    public func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "bindingKey": bindingKey,
            "state": state.rawValue,
            "consecutiveHeartbeatMisses": consecutiveHeartbeatMisses,
            "connectAttemptsThisSession": connectAttemptsThisSession,
            "wifiInFlight": wifiInFlight,
            "dockHint": dockHint.rawValue,
        ]
        if let role = role { d["role"] = role }
        if let rssi = rssi { d["rssi"] = rssi }
        if let v = lastSeenAtMs { d["lastSeenAtMs"] = v }
        if let v = lastCommandSuccessAtMs { d["lastCommandSuccessAtMs"] = v }
        if let v = lastError { d["lastError"] = v }
        if let v = lastErrorAtMs { d["lastErrorAtMs"] = v }
        if let v = dockHintLastUpdatedAtMs { d["dockHintLastUpdatedAtMs"] = v }
        if let v = batteryPercent { d["batteryPercent"] = v }
        if let v = batteryCharging { d["batteryCharging"] = v }
        return d
    }
}

// `Insta360DockStatus` is defined in `Insta360BLEController.swift` and
// reused here. The enum has no SDK-specific payload so it's safe to surface
// directly through `toDictionary()` for RN consumers.
