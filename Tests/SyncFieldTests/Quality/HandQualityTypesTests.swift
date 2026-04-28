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
