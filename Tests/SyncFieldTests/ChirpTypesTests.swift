// Tests/SyncFieldTests/ChirpTypesTests.swift
import XCTest
@testable import SyncField

final class ChirpTypesTests: XCTestCase {
    func test_default_start_chirp_is_near_ultrasonic() {
        // Default switched to 17–19 kHz to match syncfield-python's
        // ultrasound chirp; legacy audible 400→2500 Hz is now exposed
        // as ChirpSpec.audibleStart.
        let s = ChirpSpec.defaultStart
        XCTAssertEqual(s.fromHz, 17000)
        XCTAssertEqual(s.toHz, 19000)
        XCTAssertEqual(s.durationMs, 500)
        XCTAssertEqual(s.amplitude, 0.8, accuracy: 0.001)
        XCTAssertEqual(s.envelopeMs, 15)
    }

    func test_default_stop_chirp_is_reverse_ultrasonic_sweep() {
        let s = ChirpSpec.defaultStop
        XCTAssertEqual(s.fromHz, 19000)
        XCTAssertEqual(s.toHz, 17000)
    }

    func test_audible_legacy_presets_kept_for_opt_in() {
        XCTAssertEqual(ChirpSpec.audibleStart.fromHz, 400)
        XCTAssertEqual(ChirpSpec.audibleStart.toHz, 2500)
        XCTAssertEqual(ChirpSpec.audibleStop.fromHz, 2500)
        XCTAssertEqual(ChirpSpec.audibleStop.toHz, 400)
    }

    func test_chirp_spec_json_uses_snake_case() throws {
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ChirpSpec.defaultStart)) as! [String: Any]
        XCTAssertEqual(Set(dict.keys),
            ["from_hz", "to_hz", "duration_ms", "amplitude", "envelope_ms"])
    }

    func test_chirp_emission_best_ns_prefers_hardware() {
        let e1 = ChirpEmission(softwareNs: 100, hardwareNs: 200, source: .hardware)
        XCTAssertEqual(e1.bestNs, 200)
        let e2 = ChirpEmission(softwareNs: 100, hardwareNs: nil, source: .softwareFallback)
        XCTAssertEqual(e2.bestNs, 100)
    }
}
