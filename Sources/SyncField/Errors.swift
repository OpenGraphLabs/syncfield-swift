// Sources/SyncField/Errors.swift
import Foundation

public enum SessionError: Error, CustomStringConvertible, LocalizedError {
    case invalidTransition(from: SessionState, to: SessionState)
    case duplicateStreamId(String)
    case noStreamsRegistered
    case startFailed(cause: Error, rolledBack: [String])
    case manualStopRecoveryUnsupported(streamId: String)
    case notRunning
    case deviceUnsupported(reason: String)

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "SessionError: cannot transition from \(from) to \(to)"
        case .duplicateStreamId(let id):
            return "SessionError: duplicate streamId '\(id)'"
        case .noStreamsRegistered:
            return "SessionError: no streams registered"
        case .startFailed(let cause, let rolledBack):
            return "SessionError: startRecording failed (\(cause)); rolled back \(rolledBack)"
        case .manualStopRecoveryUnsupported(let streamId):
            return "SessionError: stream '\(streamId)' does not support manual stop recovery"
        case .notRunning:
            return "SessionError: operation requires the session to be running"
        case .deviceUnsupported(let reason):
            return "SessionError: device unsupported (\(reason))"
        }
    }

    public var errorDescription: String? { description }
}

/// Errors raised by the one-time `CameraCalibrationProber`. Caller (the host
/// app's bridge) decides whether to fall back gracefully or surface to the
/// user — the prober itself never silently swallows failure.
public enum ProbeError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Device has no ultra-wide camera or no photo output supporting calibration.
    case unsupportedDevice
    /// Camera permission has not been granted (or was revoked).
    case permissionDenied
    /// Probe did not produce a `cameraCalibrationData` payload within the timeout.
    case probeTimeout
    /// AVFoundation delivered a photo but `cameraCalibrationData` was nil.
    case calibrationDataMissing
    /// Catch-all for AVFoundation failures wrapped with a description.
    case underlying(String)

    public var description: String {
        switch self {
        case .unsupportedDevice: return "ProbeError: unsupported device"
        case .permissionDenied: return "ProbeError: camera permission denied"
        case .probeTimeout: return "ProbeError: probe timed out"
        case .calibrationDataMissing: return "ProbeError: calibration data missing from photo"
        case .underlying(let msg): return "ProbeError: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}

public struct StreamError: Error, CustomStringConvertible, LocalizedError {
    public let streamId: String
    public let underlying: Error

    public init(streamId: String, underlying: Error) {
        self.streamId = streamId
        self.underlying = underlying
    }

    public var description: String {
        "StreamError[\(streamId)]: \(underlying)"
    }

    public var errorDescription: String? { description }
}
