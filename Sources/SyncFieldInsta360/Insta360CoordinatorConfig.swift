import Foundation

/// Runtime configuration knobs for the Insta360 connection coordinator family.
/// Hosts (og-skill `AppDelegate.swift`) set these at process start. The whole
/// surface is mutable so dev builds can toggle subsystems on/off while running
/// the S1–S10 scenario matrix in `docs/insta360-scenario-runbook.md`.
///
/// **Default values mirror the release-build defaults.** In dev builds prefer
/// `Insta360CoordinatorConfig.shared.scenarioMode = true` which switches to a
/// verbose log floor and silences unrelated domains.
public final class Insta360CoordinatorConfig: @unchecked Sendable {
    public static let shared = Insta360CoordinatorConfig()

    public enum BLEStrategyDuringWifi: String, Sendable {
        /// Keep CoreBluetooth link to the AP-bound camera; pause heartbeat
        /// only. Empirically more reliable than tearing down + re-pair.
        case keepAlive
        /// Explicitly `bluetoothManager.disconnectDevice()` before WiFi join,
        /// reconnect after. Use as a fallback if telemetry shows the GATT
        /// link doesn't survive the AP transition.
        case disconnect
    }

    // MARK: - Connection coordinator toggles

    /// Drive Supervisor auto-reconnect on `didDisconnectWithError`. When
    /// false, the bridge falls back to the legacy reactive
    /// `attemptReconnectAllWristStreams()` foreground hook.
    public var autoReconnectEnabled: Bool = true

    /// Wrap `Insta360WiFiDownloader.downloadBatch` + `listFiles` in
    /// `RadioGate.acquireWiFi` so cross-camera BLE heartbeats throttle while
    /// another camera holds the iPhone WiFi.
    public var radioGateEnabled: Bool = true

    /// Move the foreground/background lifecycle hook out of
    /// `SyncFieldBridgeModule` into `Insta360BackgroundSupervisor`. Required
    /// when `bluetooth-central` is declared in `Info.plist` so background
    /// recordings keep heartbeats firing.
    public var backgroundBLEEnabled: Bool = true

    /// Emit `syncfield:insta360WakeStallRequiresUser` when wake escalation
    /// exceeds `wakeStallThresholdSeconds`. The RN-side modal listens and
    /// prompts the user to press the power button (or undock).
    public var wakeUserPromptEnabled: Bool = true

    /// Default 2 s. RadioGate switches to `radioGateSlowHeartbeatIntervalMs`
    /// for non-AP-bound cameras while a WiFi session is in flight.
    public var heartbeatIntervalMs: UInt64 = 2_000

    public var radioGateSlowHeartbeatIntervalMs: UInt64 = 8_000

    public var bleStrategyDuringWifi: BLEStrategyDuringWifi = .keepAlive

    /// Wake stall threshold before emitting a user prompt. 12 s by default.
    public var wakeStallThresholdSeconds: TimeInterval = 12

    /// Persistent classifier: scan windows yielding no advertisement
    /// before transitioning to `lost`.
    public var persistentScanWindowCount: Int = 3

    public var persistentScanWindowSeconds: TimeInterval = 6

    /// Beyond this idle period without any advertisement, classify as
    /// persistent rather than transient.
    public var persistentLastSeenThresholdSeconds: TimeInterval = 90

    // MARK: - Diagnostic surface

    /// Stream `syncfield:insta360HealthSnapshot` to RN every
    /// `healthSnapshotIntervalMs` ms while true. The diagnostics screen sets
    /// it on mount / off on unmount.
    public var diagnosticsEnabled: Bool = false

    public var healthSnapshotIntervalMs: UInt64 = 5_000

    // MARK: - Logging

    /// `InstaLog.minLevel` is bound to this on `apply()`. Scenario mode forces
    /// `.debug` so heartbeats etc. are visible during S1–S10 verification.
    public var minLogLevel: InstaLogLevel = .info

    /// Convenience: switch to "scenario runbook" defaults — verbose Insta360
    /// logs, terse everything else. Hosts call this from a Debug-build
    /// AppDelegate to set up before launching.
    public func enableScenarioMode() {
        scenarioMode = true
        minLogLevel = .debug
        InstaLog.minLevel = .debug
    }

    /// `true` while the host has explicitly opted into scenario mode. Used by
    /// non-Insta360 domains (e.g. OGSkillLog, SyncFieldLog) to demote chatter.
    public private(set) var scenarioMode: Bool = false

    /// Apply the active log level to the global `InstaLog`. Hosts should call
    /// this once after mutating `minLogLevel` so the next emit reflects it.
    public func apply() {
        InstaLog.minLevel = minLogLevel
    }

    private init() {}
}
