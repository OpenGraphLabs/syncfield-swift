// Sources/SyncField/Audio/ChirpTypes.swift
import Foundation

public struct ChirpSpec: Codable, Equatable, Sendable {
    public let fromHz: Double
    public let toHz: Double
    public let durationMs: Double
    public let amplitude: Double
    public let envelopeMs: Double

    public init(fromHz: Double, toHz: Double, durationMs: Double,
                amplitude: Double, envelopeMs: Double) {
        self.fromHz = fromHz; self.toHz = toHz
        self.durationMs = durationMs
        self.amplitude = amplitude
        self.envelopeMs = envelopeMs
    }

    enum CodingKeys: String, CodingKey {
        case fromHz     = "from_hz"
        case toHz       = "to_hz"
        case durationMs = "duration_ms"
        case amplitude
        case envelopeMs = "envelope_ms"
    }

    // Defaults copied verbatim from Python tone.py:54-62
    public static let defaultStart = ChirpSpec(
        fromHz: 400, toHz: 2500, durationMs: 500, amplitude: 0.8, envelopeMs: 15)

    public static let defaultStop = ChirpSpec(
        fromHz: 2500, toHz: 400, durationMs: 500, amplitude: 0.8, envelopeMs: 15)
}

public enum ChirpSource: String, Codable, Sendable {
    case hardware
    case softwareFallback = "software_fallback"
    case silent
}

public struct ChirpEmission: Sendable {
    public let softwareNs: UInt64
    public let hardwareNs: UInt64?
    public let source: ChirpSource

    public init(softwareNs: UInt64, hardwareNs: UInt64?, source: ChirpSource) {
        self.softwareNs = softwareNs
        self.hardwareNs = hardwareNs
        self.source = source
    }

    public var bestNs: UInt64 { hardwareNs ?? softwareNs }
}
