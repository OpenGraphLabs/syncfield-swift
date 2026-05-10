// Tests/SyncFieldTests/Quality/HandQualityTypesTests.swift
import XCTest
@testable import SyncField

final class HandQualityTypesTests: XCTestCase {
    func test_handSideRoundTripJSON() throws {
        let data = try JSONEncoder().encode(HandSide.left)
        let decoded = try JSONDecoder().decode(HandSide.self, from: data)
        XCTAssertEqual(decoded, .left)
    }

    func test_eventSideAccessor() {
        let evt = HandQualityEvent.outOfFrameStart(side: .right, monotonicNs: 100, frame: 5)
        XCTAssertEqual(evt.side, .right)
        XCTAssertEqual(evt.monotonicNs, 100)
    }

    func test_configDefaultsAreReasonable() {
        let c = HandQualityConfig.default
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.proximityWarningExtentNorm, 0.10, accuracy: 0.0001)
        XCTAssertGreaterThan(c.verdictGoodThreshold, c.verdictRejectThreshold)
        // Interior anchor must be wider than the near-edge proximity warning so
        // a wrist that's "interior" is unambiguously not "near edge".
        XCTAssertGreaterThan(c.interiorAnchorMarginNorm, c.proximityWarningExtentNorm)
        // Hold window must be at least as long as wrist memory; otherwise the
        // interior anchor would expire before the assignment-side memory and
        // gain nothing.
        XCTAssertGreaterThanOrEqual(c.interiorAnchorHoldMs, c.wristMemoryMs)
    }

    func test_configRoundTripPreservesInteriorAnchor() throws {
        var c = HandQualityConfig.default
        c.interiorAnchorMarginNorm = 0.25
        c.interiorAnchorHoldMs = 5000
        let data = try JSONEncoder().encode(c)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["interior_anchor_margin_norm"] as? Double, 0.25)
        XCTAssertEqual(json["interior_anchor_hold_ms"] as? Int, 5000)
        let decoded = try JSONDecoder().decode(HandQualityConfig.self, from: data)
        XCTAssertEqual(decoded.interiorAnchorMarginNorm, 0.25, accuracy: 1e-9)
        XCTAssertEqual(decoded.interiorAnchorHoldMs, 5000)
    }

    func test_configDecodesLegacyJSONWithoutInteriorAnchor() throws {
        // Older JSON payloads may omit the new fields; verify they fall back
        // to the documented defaults instead of failing to decode.
        let legacy = """
        {"enabled": true, "wrist_memory_ms": 2500}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HandQualityConfig.self, from: legacy)
        XCTAssertEqual(decoded.interiorAnchorMarginNorm, 0.20, accuracy: 1e-9)
        XCTAssertEqual(decoded.interiorAnchorHoldMs, 8000)
    }

    func test_qualityStatsRoundTripJSONUsesSnakeCase() throws {
        let stats = QualityStats(
            handInFramePct: 0.873,
            leftInFramePct: 0.92,
            rightInFramePct: 0.83,
            nearEdgeEventCount: 4,
            outOfFrameEventCount: 2,
            outOfFrameTotalSeconds: 5.5,
            recordingDurationSeconds: 60.0
        )
        let data = try JSONEncoder().encode(stats)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["hand_in_frame_pct"] as? Double, 0.873)
        XCTAssertEqual(json["near_edge_event_count"] as? Int, 4)
        let decoded = try JSONDecoder().decode(QualityStats.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}
