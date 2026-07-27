// Sources/SyncField/Streams/Tactile/TactileAcquireFailure.swift
import Foundation

/// Maps glove acquire-loop errors to stable, analytics-friendly reason
/// strings. These flow through `HealthEvent.streamDisconnected(reason:)`
/// to the host app, which surfaces them on the discovery row and in
/// telemetry — so the strings are a contract: keep them stable.
public enum TactileAcquireFailure {
    public static func reason(for error: Error) -> String {
        // TactileBLEClient.Error only exists where CoreBluetooth does.
        #if canImport(CoreBluetooth)
        switch error {
        case TactileBLEClient.Error.scanTimeout:
            return "scan_timeout"
        case TactileBLEClient.Error.bluetoothUnavailable:
            return "bluetooth_unavailable"
        case TactileBLEClient.Error.unsupportedSchema(let version):
            return "unsupported_schema_\(version)"
        default:
            // Everything else (connect timeout, service discovery failure,
            // manifest read/parse) is a transient link problem the loop
            // retries; one bucket keeps the taxonomy small.
            return "connect_failed"
        }
        #else
        return "connect_failed"
        #endif
    }
}

/// Dedupes repeated identical failure publishes: an absent glove hits
/// `scan_timeout` every ~13.5 s cycle, and only the first occurrence (or a
/// change of reason) is worth an event. `reset()` after a successful
/// connect so a later failure of the same kind publishes again.
public struct TactileAcquireFailureDeduper {
    private var lastReason: String?

    public init() {}

    public mutating func shouldPublish(_ reason: String) -> Bool {
        guard reason != lastReason else { return false }
        lastReason = reason
        return true
    }

    public mutating func reset() {
        lastReason = nil
    }
}
