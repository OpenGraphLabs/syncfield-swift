// Sources/SyncField/Errors.swift
import Foundation

public enum SessionError: Error, CustomStringConvertible, LocalizedError {
    case invalidTransition(from: SessionState, to: SessionState)
    case duplicateStreamId(String)
    case noStreamsRegistered
    case startFailed(cause: Error, rolledBack: [String])
    case manualStopRecoveryUnsupported(streamId: String)
    case notRunning

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
