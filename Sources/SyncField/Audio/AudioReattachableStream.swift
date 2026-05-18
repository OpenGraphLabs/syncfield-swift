// Sources/SyncField/Audio/AudioReattachableStream.swift
import Foundation

/// Implemented by streams whose audio input can be detached and reattached
/// without tearing down the entire capture pipeline. Used by
/// `SessionOrchestrator.recoverFromInterruption()` to restore the audio
/// path after an `AVAudioSession.interruptionNotification` `.ended` event,
/// and by each stream's own internal watchdog for sample-buffer stalls.
///
/// The protocol intentionally exposes only `reattachAudioInput`. Streams
/// that don't carry audio (sensor-only) don't conform; the orchestrator
/// `as?`-casts to filter.
public protocol AudioReattachableStream: AnyObject, Sendable {
    /// Re-create the audio capture input and attach it to the running
    /// capture session. Implementations must be safe to call while
    /// recording is in progress; a brief reconfiguration window is
    /// acceptable. Throws if the device is unavailable or the input
    /// cannot be added.
    func reattachAudioInput() async throws
}
