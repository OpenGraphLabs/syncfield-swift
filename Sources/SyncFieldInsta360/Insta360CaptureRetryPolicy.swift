import Foundation

internal enum Insta360CaptureRetryPolicy {
    static let maxStartAttempts = 3
    static let maxStopAttempts = 4
    static let recordingSafetyLimitSeconds: UInt32 = 1_800

    static func startTimeoutSeconds(attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 6
        case 2: return 8
        default: return 10
        }
    }

    static func stopTimeoutSeconds(attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 6
        case 2: return 10
        case 3: return 14
        default: return 18
        }
    }

    static func stopBackoffNs(afterAttempt attempt: Int) -> UInt64 {
        switch attempt {
        case 1: return 500_000_000
        case 2: return 1_250_000_000
        default: return 2_500_000_000
        }
    }

    static func isRecoverableCommandError(_ error: Error) -> Bool {
        if case Insta360Error.notPaired = error { return true }
        let normalized = normalizedMessage(error)
        return normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("unavailable")
            || normalized.contains("not ready")
            || normalized.contains("not paired")
            || normalized.contains("disconnected")
            || normalized.contains("disconnect")
            || normalized.contains("ble")
            || normalized.contains("bluetooth")
            || normalized.contains("msg execute err")
            || normalized.contains("execute err")
            || normalized.contains("busy")
            || normalized.contains("444")
    }

    static func indicatesAlreadyStopped(_ error: Error) -> Bool {
        let normalized = normalizedMessage(error)
        return normalized.contains("not capturing")
            || normalized.contains("not capture")
            || normalized.contains("not recording")
            || normalized.contains("not record")
            || normalized.contains("not started")
            || normalized.contains("already stopped")
            || normalized.contains("capture stopped")
    }

    private static func normalizedMessage(_ error: Error) -> String {
        if case Insta360Error.commandFailed(let detail) = error {
            return detail.lowercased()
        }
        return error.localizedDescription.lowercased()
    }
}
