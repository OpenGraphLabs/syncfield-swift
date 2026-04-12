// Sources/SyncField/HealthEvent.swift
import Foundation

public enum HealthEvent: Sendable {
    case streamConnected(streamId: String)
    case streamDisconnected(streamId: String, reason: String)
    case samplesDropped(streamId: String, count: Int)
    case ingestProgress(streamId: String, fraction: Double)
    case ingestFailed(streamId: String, error: Error)
}
