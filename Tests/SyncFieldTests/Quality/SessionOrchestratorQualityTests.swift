// Tests/SyncFieldTests/Quality/SessionOrchestratorQualityTests.swift
//
// End-to-end orchestrator integration: a recording session with
// ingestHandObservations + logEvent should produce both events.jsonl
// and hand_quality.json in the episode directory.

import XCTest
@testable import SyncField

final class SessionOrchestratorQualityTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-quality-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func centered(_ side: HandSide) -> HandObservation {
        HandObservation(
            chirality: side, chiralityConfidence: 0.9,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.5, 0.5) },
            wrist: SIMD2(0.5, 0.5)
        )
    }

    func test_recordingProducesQualityArtifacts() async throws {
        // Disable startup grace so the test can drive a tiny synthetic
        // timeline without waiting a real second.
        var cfg = HandQualityConfig.default
        cfg.startupGraceMs = 0
        cfg.oofDebounceMs = 100
        cfg.recoveryDebounceMs = 50

        let session = SessionOrchestrator(
            hostId: "test-host",
            outputDirectory: tmpDir,
            chirpPlayer: SilentChirpPlayer(),
            startChirp: nil,
            stopChirp: nil,
            handQualityConfig: cfg
        )
        try await session.add(MockStream(streamId: "cam_ego"))
        try await session.connect()
        _ = try await session.startRecording()

        // We use real monotonic time for ingest so close-times never
        // precede start-times. The recording lasts ~750ms.
        let frameStepMs: UInt64 = 50
        for i in 0..<3 {
            await session.ingestHandObservations(
                [centered(.left), centered(.right)],
                frame: i,
                monotonicNs: nowMonotonicNs()
            )
            try? await Task.sleep(nanoseconds: frameStepMs * 1_000_000)
        }
        // Drop left for ~400ms (well past 100ms debounce)
        for i in 3..<11 {
            await session.ingestHandObservations(
                [centered(.right)],
                frame: i,
                monotonicNs: nowMonotonicNs()
            )
            try? await Task.sleep(nanoseconds: frameStepMs * 1_000_000)
        }
        // Recover for ~150ms
        for i in 11..<14 {
            await session.ingestHandObservations(
                [centered(.left), centered(.right)],
                frame: i,
                monotonicNs: nowMonotonicNs()
            )
            try? await Task.sleep(nanoseconds: frameStepMs * 1_000_000)
        }

        try await session.logEvent(
            kind: "audio_cue_route_set",
            monotonicNs: nowMonotonicNs(),
            endMonotonicNs: nil,
            payload: ["route": "Speaker"]
        )

        _ = try await session.stopRecording()

        let episodeDir = await session.episodeDirectory
        let eventsURL = episodeDir.appendingPathComponent("events.jsonl")
        let qualityURL = episodeDir.appendingPathComponent("hand_quality.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL.path),
                      "events.jsonl should be written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: qualityURL.path),
                      "hand_quality.json should be written")

        let lines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        let kinds: Set<String> = Set(lines.compactMap { line -> String? in
            let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return obj?["kind"] as? String
        })
        XCTAssertTrue(kinds.contains("hand_out_of_frame"))
        XCTAssertTrue(kinds.contains("audio_cue_route_set"))

        let summary = try JSONDecoder().decode(
            HandQualitySummary.self,
            from: Data(contentsOf: qualityURL)
        )
        XCTAssertGreaterThan(summary.raw.outOfFrameEventCount, 0)
        XCTAssertLessThan(summary.subScores.leftInFramePct, 1.0)
        XCTAssertEqual(summary.subScores.rightInFramePct, 1.0, accuracy: 0.01)
    }

    private func nowMonotonicNs() -> UInt64 {
        // Mirrors SessionClock.nowMonotonicNs; using mach_absolute_time directly
        // means the test doesn't depend on grabbing the orchestrator's private clock.
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = mach_absolute_time()
        return ticks &* UInt64(tb.numer) / UInt64(tb.denom)
    }
}
