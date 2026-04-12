// Sources/SyncField/SessionState.swift
import Foundation

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle
    case connected
    case recording
    case stopping
    case ingesting
}
