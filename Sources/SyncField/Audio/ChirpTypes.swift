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

    // MARK: - Defaults
    //
    // Defaults moved to the 17–19 kHz near-ultrasonic band so the sync
    // chirp doesn't disrupt the user during recording. Validated end-to-
    // end in syncfield-python (`tone.py`) against an Insta360 Go 3S mic
    // + AAC encoder and a MacBook built-in speaker: the 17–19 kHz chirp
    // survives the recording path with ~+20 dB SNR, well above the
    // event-detector's 5× prominence floor used by the syncfield sync
    // API. Adult hearing typically rolls off above 15–16 kHz so most
    // users won't hear it; at the same time the band stays under 19 kHz
    // where some MacBook tweeters / AAC encoders start dropping content.
    //
    // The rising/falling asymmetry between start and stop is preserved
    // so the alignment core can still distinguish them via direction.

    /// Start chirp — rising 17 → 19 kHz, 500 ms. Near-inaudible default.
    public static let defaultStart = ChirpSpec(
        fromHz: 17000, toHz: 19000, durationMs: 500, amplitude: 0.8, envelopeMs: 15)

    /// Stop chirp — falling 19 → 17 kHz, 500 ms. Near-inaudible default.
    public static let defaultStop = ChirpSpec(
        fromHz: 19000, toHz: 17000, durationMs: 500, amplitude: 0.8, envelopeMs: 15)

    // MARK: - Audible (opt-in legacy)
    //
    // The 400–2500 Hz audible chirps that were the default before the
    // ultrasonic switch. Use cases for opting in:
    //   1. cameras / codecs with an audio cutoff below ~16 kHz where the
    //      ultrasonic chirp doesn't survive the recording pipeline,
    //   2. debugging scenarios where the operator wants to HEAR that the
    //      chirps actually fired,
    //   3. demos / accessibility workflows that need a human-audible cue.

    /// Audible legacy start chirp — rising 400 → 2500 Hz, 500 ms.
    public static let audibleStart = ChirpSpec(
        fromHz: 400, toHz: 2500, durationMs: 500, amplitude: 0.8, envelopeMs: 15)

    /// Audible legacy stop chirp — falling 2500 → 400 Hz, 500 ms.
    public static let audibleStop = ChirpSpec(
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
