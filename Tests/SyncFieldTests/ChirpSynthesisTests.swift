// Tests/SyncFieldTests/ChirpSynthesisTests.swift
import XCTest
@testable import SyncField

final class ChirpSynthesisTests: XCTestCase {
    func test_synthesize_produces_expected_sample_count() {
        let spec = ChirpSpec(fromHz: 1000, toHz: 1000, durationMs: 100,
                             amplitude: 1.0, envelopeMs: 0)
        let samples = ChirpSynthesis.render(spec, sampleRate: 44100)
        // 100ms at 44.1 kHz = 4410 samples
        XCTAssertEqual(samples.count, 4410)
    }

    func test_synthesize_respects_amplitude() {
        let spec = ChirpSpec(fromHz: 1000, toHz: 1000, durationMs: 10,
                             amplitude: 0.5, envelopeMs: 0)
        let samples = ChirpSynthesis.render(spec, sampleRate: 44100)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.5 + 1e-6)
        XCTAssertGreaterThan(peak, 0.4)  // should reach near amplitude
    }

    func test_envelope_tapers_ends_to_zero() {
        let spec = ChirpSpec(fromHz: 1000, toHz: 1000, durationMs: 100,
                             amplitude: 1.0, envelopeMs: 15)
        let samples = ChirpSynthesis.render(spec, sampleRate: 44100)
        // First and last sample should be very close to zero due to envelope
        XCTAssertLessThan(abs(samples.first!), 0.05)
        XCTAssertLessThan(abs(samples.last!), 0.05)
    }
}
