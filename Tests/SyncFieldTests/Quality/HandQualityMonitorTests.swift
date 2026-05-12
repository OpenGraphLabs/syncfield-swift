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
        // Existing semantics test: with occlusion-hold disabled, missing
        // observations flow through the OOF debounce and fire normally.
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        cfg.occlusionHoldEnabled = false
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
        var cfg = HandQualityConfig.default
        cfg.occlusionHoldEnabled = false   // see note in debounce test above
        let m = HandQualityMonitor(
            config: cfg,
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
        var cfg = HandQualityConfig.default
        cfg.occlusionHoldEnabled = false   // exercise raw OOF accounting
        let m = HandQualityMonitor(
            config: cfg,
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

    // MARK: - wrist-centric + occlusion-hold

    /// Hand whose wrist is well inside the frame interior but only two
    /// confident keypoints survive (extreme occlusion / partial detection
    /// during a grip). The previous bbox-extents rule rejected anything
    /// below ``minConfidentKeypointsForBbox`` (5) as outOfFrame; the new
    /// rule keys off the wrist anchor so a partial detection over the
    /// centre of the frame stays inFrame.
    private func partialHand(_ side: HandSide,
                             wrist: SIMD2<Double>,
                             keypointCount: Int) -> HandObservation {
        HandObservation(
            chirality: side,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<keypointCount).map { _ in wrist },
            wrist: wrist
        )
    }

    func test_partialDetection_centerWrist_stillInFrame() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        for i in 0..<10 {
            // Two-keypoint partial detection — used to be rejected as OOF.
            await m.ingest(observations: [partialHand(.left,
                                                       wrist: SIMD2(0.5, 0.5),
                                                       keypointCount: 2),
                                          centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 10 * frameStepNs, stopFrame: 10)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart = $0 { return true }
            return false
        })
        XCTAssertFalse(emitted.contains {
            if case .nearEdgeStart = $0 { return true }
            return false
        })
    }

    /// MediaPipe occasionally drops the back hand entirely while two
    /// hands are pressed together (washing / rubbing). The cached wrist
    /// from the previous frame should keep that side classified inFrame
    /// for the wrist-memory window instead of firing OOF after the
    /// 200 ms debounce.
    func test_occlusionHold_centerWristMissingDoesNotFireOOF() async throws {
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        cfg.wristMemoryMs = 1500
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        // Establish the left hand at frame center.
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        // 8 frames × 100 ms = 800 ms with the back hand missing — well
        // past the 200 ms OOF debounce but inside the 1500 ms wrist memory.
        for i in 1...8 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 9 * frameStepNs, stopFrame: 9)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        })
    }

    /// When the cached wrist sat right at the frame edge, the hand was
    /// on its way out — occlusion-hold must NOT suppress the OOF.
    func test_occlusionHold_edgeWristStillFiresOOF() async throws {
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        // Last seen at the very left edge — within edgeExitMargin.
        let leavingHand = HandObservation(
            chirality: .left,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.02, 0.5) },
            wrist: SIMD2(0.02, 0.5)
        )
        await m.ingest(observations: [leavingHand, centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        for i in 1...4 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 5 * frameStepNs, stopFrame: 5)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        })
    }

    /// Once the wrist memory window expires, occlusion-hold releases and
    /// OOF fires.
    ///
    /// Note: this exercises the legacy edge-zone wrist memory in
    /// isolation, so the interior anchor (a longer-lived hold introduced
    /// after this test was written) is explicitly disabled. The interior
    /// anchor's own expiry behavior is covered by
    /// ``test_interiorAnchor_releasesAfterHoldMs``.
    func test_occlusionHold_expiresAfterWristMemory() async throws {
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        cfg.wristMemoryMs = 500
        cfg.interiorAnchorHoldMs = 0
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        // 12 frames × 100 ms = 1200 ms, well past the 500 ms wrist memory.
        for i in 1...12 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 13 * frameStepNs, stopFrame: 13)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        })
    }

    /// A hand observation arriving with no wrist but a couple of confident
    /// palm-region keypoints near the centre should still register
    /// inFrame via the centroid fallback.
    // MARK: - interior anchor (FP-cue suppression)

    /// Egocentric seed-clip case: the user grips a vacuum stick / reaches
    /// into a closet. MediaPipe loses the left hand entirely for several
    /// seconds, even though the wrist was last seen near the centre of the
    /// frame and the hand is physically still there. The interior anchor
    /// must hold the side as inFrame for the full ``interiorAnchorHoldMs``
    /// window so the audio cue does not fire.
    func test_interiorAnchor_holdsThroughLongOcclusionAtCenter() async throws {
        let cfg = HandQualityConfig.default   // interiorAnchorHoldMs = 8000
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        // Establish both hands at frame centre (deep interior).
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        // 60 frames × 100 ms = 6000 ms with the left hand missing — 4× the
        // assignment-side wrist memory (1500 ms default), but still inside
        // the 8000 ms interior anchor window.
        for i in 1...60 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 61 * frameStepNs, stopFrame: 61)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        }, "interior anchor should suppress OOF for left hand last seen at frame centre")
    }

    /// The interior anchor MUST release shortly after a fresh observation
    /// places the wrist into the edge zone — otherwise a hand that
    /// visibly walks toward the edge and then drops out would be pinned
    /// IN forever.
    ///
    /// The policy is *decay*, not instant invalidation: an edge-zone wrist
    /// shrinks the anchor expiry to ``interiorAnchorEdgeDecayMs`` (~1.5 s)
    /// from the brush, so a hand that genuinely continues past the edge
    /// still produces OOF within roughly that window plus
    /// ``oofDebounceMs``, while a transient edge brush followed by an
    /// interior re-detection re-arms the full hold. Instant clearing was
    /// the prior policy and re-introduced multi-second OOF false
    /// positives on chair-grip / sleeve-occlusion manipulation.
    func test_interiorAnchor_releasesShortlyAfterEdgeObservation() async throws {
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        // Step 1: hand at centre — interior anchor armed at base + 8000 ms.
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        // Step 2: hand walks to the very left edge (well inside
        // edgeExitMargin = 0.05). The interior anchor expiry must shrink
        // to ~1.5 s from this brush and the edge-zone path must then
        // classify the subsequent missing-observation frames as
        // outOfFrame so the OOF debounce can fire.
        let leavingHand = HandObservation(
            chirality: .left,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.02, 0.5) },
            wrist: SIMD2(0.02, 0.5)
        )
        await m.ingest(observations: [leavingHand, centeredHand(.right)],
                       frame: 1, monotonicNs: base + frameStepNs)
        // Step 3+: hand disappears entirely. Run past the decay tail
        // (~1.5 s) plus the OOF debounce (200 ms) with margin so the
        // OOF event has time to fire.
        for i in 2...25 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 26 * frameStepNs, stopFrame: 26)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        }, "OOF must still fire when the last fresh observation was in the edge zone")
    }

    /// A transient edge brush followed by an interior re-detection must
    /// NOT cause OOF — the anchor decays on the brush but is re-armed by
    /// the next interior wrist, so a subsequent multi-second occlusion
    /// stays suppressed. This is the chair-grip / sleeve-occlusion
    /// manipulation case the decay policy exists to fix.
    func test_interiorAnchor_edgeBrushRecoversOnInteriorRefresh() async throws {
        var cfg = HandQualityConfig.default
        cfg.oofDebounceMs = 200
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        // Centre → anchor armed.
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        // Single-frame edge brush.
        let brush = HandObservation(
            chirality: .left,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.05, 0.5) },
            wrist: SIMD2(0.05, 0.5)
        )
        await m.ingest(observations: [brush, centeredHand(.right)],
                       frame: 1, monotonicNs: base + frameStepNs)
        // Interior re-detection — must re-arm anchor to the full hold.
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 2, monotonicNs: base + 2 * frameStepNs)
        // 50 frames × 100 ms = 5000 ms with the left hand missing — well
        // past the 1500 ms decay tail and the 1500 ms assignment-side
        // wrist memory, but inside the re-armed 8000 ms anchor.
        for i in 3...52 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 53 * frameStepNs, stopFrame: 53)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        }, "edge brush followed by interior re-detection must not fire OOF")
    }

    /// Interior anchor must release after ``interiorAnchorHoldMs`` so a hand
    /// that genuinely stays out of view longer than the hold still produces
    /// an OOF event for downstream quality scoring.
    func test_interiorAnchor_releasesAfterHoldMs() async throws {
        var cfg = HandQualityConfig.default
        cfg.interiorAnchorHoldMs = 500    // tighten so the test is fast
        cfg.wristMemoryMs = 200
        cfg.oofDebounceMs = 100
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        // 12 frames × 100 ms = 1200 ms, well past both the 500 ms interior
        // anchor and the 200 ms assignment memory.
        for i in 1...12 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 13 * frameStepNs, stopFrame: 13)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        }, "interior anchor must release after interiorAnchorHoldMs and let OOF fire")
    }

    /// Disabling the interior anchor (hold = 0) restores the legacy
    /// behavior — OOF fires after the wrist memory expires regardless of
    /// where the wrist was last seen.
    func test_interiorAnchor_disabledByZeroHoldMs() async throws {
        var cfg = HandQualityConfig.default
        cfg.interiorAnchorHoldMs = 0      // disabled
        cfg.wristMemoryMs = 500
        cfg.oofDebounceMs = 200
        let m = HandQualityMonitor(
            config: cfg,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        await m.ingest(observations: [centeredHand(.left), centeredHand(.right)],
                       frame: 0, monotonicNs: base)
        for i in 1...12 {
            await m.ingest(observations: [centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 13 * frameStepNs, stopFrame: 13)
        let emitted = await task.value
        XCTAssertTrue(emitted.contains {
            if case .outOfFrameStart(.left, _, _) = $0 { return true }
            return false
        }, "with interiorAnchorHoldMs=0 the legacy wrist-memory path must drive OOF")
    }

    /// Cardinality cap: even if the detector hands us 3+ observations in
    /// one frame (numHands enforcement bug, weird upstream variant), the
    /// monitor must process at most 1 left + 1 right.
    func test_ingest_capsObservationsAtTwo() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        // Three observations: a stray third hand at the bottom edge that, if
        // not capped, could pollute side assignment.
        let stray = HandObservation(
            chirality: .left,
            chiralityConfidence: 0.95,
            confidentKeypoints: (0..<10).map { _ in SIMD2(0.5, 0.97) },
            wrist: SIMD2(0.5, 0.97)
        )
        for i in 0..<10 {
            await m.ingest(observations: [centeredHand(.left), centeredHand(.right), stray],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 10 * frameStepNs, stopFrame: 10)
        let emitted = await task.value
        // The stray bottom-edge hand must NOT pull either side into nearEdge
        // or OOF. If the cap works, only the two centered observations drive
        // the state machine.
        XCTAssertFalse(emitted.contains {
            if case .nearEdgeStart = $0 { return true }
            return false
        })
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart = $0 { return true }
            return false
        })
    }

    func test_partialDetection_noWrist_centroidUsed() async throws {
        let m = HandQualityMonitor(
            config: .default,
            recordingStartMonotonicNs: 0,
            eventWriter: makeWriter()
        )
        let task = collect(m.events)
        let base: UInt64 = 2_000_000_000
        let palmOnly = HandObservation(
            chirality: .left,
            chiralityConfidence: 0.95,
            confidentKeypoints: [SIMD2(0.45, 0.5), SIMD2(0.55, 0.5), SIMD2(0.5, 0.55)],
            wrist: nil
        )
        for i in 0..<10 {
            await m.ingest(observations: [palmOnly, centeredHand(.right)],
                           frame: i, monotonicNs: base + UInt64(i) * frameStepNs)
        }
        await m.finalize(stopMonotonicNs: base + 10 * frameStepNs, stopFrame: 10)
        let emitted = await task.value
        XCTAssertFalse(emitted.contains {
            if case .outOfFrameStart = $0 { return true }
            return false
        })
    }
}
