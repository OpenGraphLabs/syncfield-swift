// Tests/SyncFieldTests/Quality/HandQualitySummaryTests.swift
import XCTest
@testable import SyncField

final class HandQualitySummaryTests: XCTestCase {
    func test_verdictMapping() {
        let cfg = HandQualityConfig.default

        let goodStats = QualityStats(
            handInFramePct: 0.97, leftInFramePct: 0.97, rightInFramePct: 0.99,
            nearEdgeEventCount: 0, outOfFrameEventCount: 0, outOfFrameTotalSeconds: 0,
            recordingDurationSeconds: 100
        )
        XCTAssertEqual(HandQualitySummaryBuilder.build(stats: goodStats, config: cfg).verdict, .good)

        let rejStats = QualityStats(
            handInFramePct: 0.65, leftInFramePct: 0.7, rightInFramePct: 0.95,
            nearEdgeEventCount: 4, outOfFrameEventCount: 6, outOfFrameTotalSeconds: 35,
            recordingDurationSeconds: 100
        )
        XCTAssertEqual(HandQualitySummaryBuilder.build(stats: rejStats, config: cfg).verdict, .reject)

        let margStats = QualityStats(
            handInFramePct: 0.87, leftInFramePct: 0.9, rightInFramePct: 0.85,
            nearEdgeEventCount: 1, outOfFrameEventCount: 1, outOfFrameTotalSeconds: 5,
            recordingDurationSeconds: 100
        )
        XCTAssertEqual(HandQualitySummaryBuilder.build(stats: margStats, config: cfg).verdict, .marginal)
    }

    func test_writeProducesParsableJson() throws {
        let cfg = HandQualityConfig.default
        let stats = QualityStats(
            handInFramePct: 0.9, leftInFramePct: 0.9, rightInFramePct: 0.95,
            nearEdgeEventCount: 1, outOfFrameEventCount: 1, outOfFrameTotalSeconds: 3,
            recordingDurationSeconds: 30
        )
        let summary = HandQualitySummaryBuilder.build(stats: stats, config: cfg)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hq-\(UUID()).json")
        try HandQualitySummaryBuilder.write(summary, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try JSONDecoder().decode(HandQualitySummary.self, from: Data(contentsOf: url))
        XCTAssertEqual(parsed.verdict, .marginal)
        XCTAssertEqual(parsed.raw.recordingDurationSeconds, 30, accuracy: 0.01)
        XCTAssertEqual(parsed.subScores.leftInFramePct, 0.9, accuracy: 0.001)
    }

    func test_writeUsesSnakeCaseKeys() throws {
        let cfg = HandQualityConfig.default
        let stats = QualityStats(
            handInFramePct: 0.9, leftInFramePct: 0.9, rightInFramePct: 0.95,
            nearEdgeEventCount: 1, outOfFrameEventCount: 1, outOfFrameTotalSeconds: 3,
            recordingDurationSeconds: 30
        )
        let summary = HandQualitySummaryBuilder.build(stats: stats, config: cfg)
        let data = try JSONEncoder().encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["overall_score"])
        XCTAssertNotNil(json["sub_scores"])
        let sub = json["sub_scores"] as! [String: Any]
        XCTAssertNotNil(sub["left_in_frame_pct"])
        XCTAssertNotNil(sub["both_in_frame_pct"])
        let raw = json["raw"] as! [String: Any]
        XCTAssertNotNil(raw["hand_in_frame_pct"])
        XCTAssertNotNil(raw["near_edge_event_count"])
    }
}
