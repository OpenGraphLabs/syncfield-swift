// Sources/SyncField/HealthEvent.swift
import Foundation

public enum HealthEvent: Sendable {
    case streamConnected(streamId: String)
    case streamDisconnected(streamId: String, reason: String)
    case samplesDropped(streamId: String, count: Int)
    case ingestProgress(streamId: String, fraction: Double)
    case ingestFailed(streamId: String, error: Error)

    /// Audio sample buffers stopped flowing to the AVAssetWriter for
    /// `silentForSeconds`. Emitted by the watchdog on `iPhoneCameraStream`
    /// when the AVCaptureAudioDataOutput delegate is silent past the
    /// stall threshold. May fire repeatedly while the stall persists.
    case audioStalled(streamId: String, silentForSeconds: Double)
    /// Audio sample buffers resumed after a stall or interruption. Emitted
    /// once when the watchdog or the AVAudioSession interruption handler
    /// completes a successful reattach.
    case audioRecovered(streamId: String)
}
