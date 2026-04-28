// Tests/SyncFieldTests/Quality/HandQualityMonitorTests.swift
import XCTest
@testable import SyncField

final class HandQualityMonitorTests: XCTestCase {
    let frameStepNs: UInt64 = 100_000_000   // 100 ms = 10 Hz
    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hqm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeWriter() -> EventWriter {
        EventWriter(fileURL: tmpDir.appendingPathComponent("events.jsonl"))
    }

    private func centeredHand(_ side: HandSide) -> HandObservation {
        HandObservation(
            chirality: side,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.5, 0.5) },
            wrist: SIMD2(0.5, 0.5)
        )
    }

    private func edgeHand(_ side: HandSide) -> HandObservation {
        HandObservation(
            chirality: side,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.05, 0.5) },
            wrist: SIMD2(0.05, 0.5)
        )
    }

    private func collect(_ stream: AsyncStream<HandQualityEvent>) -> Task<[HandQualityEvent], Never> {
        Task {
            var collected: [HandQualityEvent] = []
            for await e in stream {
                collected.append(e)
            }
            return collected
        }
    }

    func test_inFrameStable_emitsNoEvents() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        for i in 0..<30 {
            let ts = UInt64(i) * frameStepNs + 2_000_000_000
            await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                           frame: i, monotonicNs: ts)
        }
        await m.finalize(stopMonotonicNs: 30 * frameStepNs + 2_000_000_000, stopFrame: 30)
        let emitted = await task.value
        XCTAssertTrue(emitted.isEmpty)
    }

    func test_nearEdgeEntry_emitsImmediately() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)

        let baseTs: UInt64 = 2_000_000_000
        for i in 0..<3 {
            await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                            frame: i, monotonicNs: baseTs + UInt64(i) * frameStepNs)
        }
        await m.ingest(observations: [edgeHand(.left), centeredHand(.right)],
                        frame: 3, monotonicNs: baseTs + 3 * frameStepNs)
        await m.finalize(stopMonotonicNs: baseTs + 4 * frameStepNs, stopFrame: 4)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .nearEdgeStart(.left, _, _, _) = $0 { return true }
            return false
        })
    }

    func test_oofDebounce_singleFrameDropSuppressed() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)

        let baseTs: UInt64 = 2_000_000_000
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: baseTs)
        await m.ingest(observations: [centeredHand(.right)],
                       frame: 1, monotonicNs: baseTs + frameStepNs)
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 2, monotonicNs: baseTs + 2 * frameStepNs)
        await m.finalize(stopMonotonicNs: baseTs + 3 * frameStepNs, stopFrame: 3)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart = $0 { return true }
            return false
        })
    }

    func test_oofDebounce_firesAfterContinuousAbsence() async throws {
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)

        let baseTs: UInt64 = 2_000_000_000
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: baseTs)
        for i in 1...4 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: baseTs + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: baseTs + 5 * frameStepNs, stopFrame: 5)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        })
    }

    func test_startupGrace_suppressesColdStart() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        for i in 0..<8 {
            await m.ingest(observations: [], frame: i, monotonicNs: UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: 8 * frameStepNs, stopFrame: 8)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart = $0 { return true }
            return false
        })
    }

    func test_finalize_closesOpenOofIntervals() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)

        let baseTs: UInt64 = 2_000_000_000
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: baseTs)
        for i in 1...5 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: baseTs + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: baseTs + 6 * frameStepNs, stopFrame: 6)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        })
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameEnd(.left, _, _) = $0 { return true }
            return false
        })
    }

    func test_qualityStats_reportsCorrectPercents() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 2_000_000_000,
            eventWriter: makeWriter()
        )
        let baseTs: UInt64 = 3_000_000_000  // past grace at recordingStart=2s
        for i in 0..<10 {
            await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                           frame: i, monotonicNs: baseTs + UInt64(i) * frameStepNs)
        }
        for i in 10..<15 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: baseTs + UInt64(i) * frameStepNs)
        }
        let stop = baseTs + 15 * frameStepNs
        let stats = await m.qualityStats(recordingStartMonotonicNs: baseTs,
                                         stopMonotonicNs: stop)
        await m.finalize(stopMonotonicNs: stop, stopFrame: 15)

        XCTAssertEqual(stats.recordingDurationSeconds, 1.5, accuracy: 0.01)
        XCTAssertGreaterThan(stats.leftInFramePct, 0.5)
        XCTAssertLessThan(stats.leftInFramePct, 0.85)
        XCTAssertEqual(stats.rightInFramePct, 1.0, accuracy: 0.01)
    }
}
