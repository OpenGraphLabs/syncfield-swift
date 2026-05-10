// Sources/SyncField/Quality/HandQualityMonitor.swift
import Foundation

/// Lightweight, test-friendly view of one detected hand. Built from a
/// `VNHumanHandPoseObservation` by ``VisionHandConversion`` on the host
/// app side, but the monitor itself stays Vision-free for portability
/// and unit-testability.
public struct HandObservation: Sendable, Equatable {
    public let chirality: HandSide?
    public let chiralityConfidence: Double
    public let confidentKeypoints: [SIMD2<Double>]
    public let wrist: SIMD2<Double>?

    public init(chirality: HandSide?,
                chiralityConfidence: Double,
                confidentKeypoints: [SIMD2<Double>],
                wrist: SIMD2<Double>?) {
        self.chirality = chirality
        self.chiralityConfidence = chiralityConfidence
        self.confidentKeypoints = confidentKeypoints
        self.wrist = wrist
    }
}

/// Per-hand FOV state machine driven by Vision hand-pose observations.
///
/// Consumes one ``ingest(observations:frame:monotonicNs:)`` call per
/// frame, runs the IN / NEAR_EDGE / OUT_OF_FRAME state machine
/// independently for each hand, writes interval records to
/// ``EventWriter``, and emits state transitions on the public
/// ``events`` stream so consumers can drive UI / audio cues live.
public actor HandQualityMonitor {
    public enum State: Sendable, Equatable { case inFrame, nearEdge, outOfFrame }

    private let config: HandQualityConfig
    private let eventWriter: EventWriter
    private let recordingStartNs: UInt64
    private let continuation: AsyncStream<HandQualityEvent>.Continuation
    public nonisolated let events: AsyncStream<HandQualityEvent>

    private struct SideState {
        var state: State = .inFrame
        var pendingState: State = .inFrame
        var pendingSinceNs: UInt64 = 0
        var lastWrist: SIMD2<Double>? = nil
        var wristMemoryExpiresNs: UInt64 = 0
        /// Sticky "deepest known interior" anchor for FP-cue suppression.
        /// Refreshed only when an observation arrives with a wrist that is
        /// further than ``HandQualityConfig/interiorAnchorMarginNorm`` from
        /// any frame edge. Invalidated as soon as a fresh observation lands
        /// in the edge zone, when the side transitions to ``outOfFrame``,
        /// or when ``interiorAnchorExpiresNs`` is reached.
        var lastInteriorWrist: SIMD2<Double>? = nil
        var interiorAnchorExpiresNs: UInt64 = 0
        var openNearEdgeHandle: EventHandle? = nil
        var openOofHandle: EventHandle? = nil
        var nearEdgeAccumulatedNs: UInt64 = 0
        var oofAccumulatedNs: UInt64 = 0
        var lastNearEdgeStartNs: UInt64 = 0
        var lastOofStartNs: UInt64 = 0
        var nearEdgeCount: Int = 0
        var oofCount: Int = 0
    }

    private var leftState = SideState()
    private var rightState = SideState()
    private let startupGraceUntilNs: UInt64

    public init(config: HandQualityConfig,
                recordingStartMonotonicNs: UInt64,
                eventWriter: EventWriter) {
        self.config = config
        self.eventWriter = eventWriter
        self.recordingStartNs = recordingStartMonotonicNs
        self.startupGraceUntilNs = recordingStartMonotonicNs
            &+ UInt64(config.startupGraceMs) * 1_000_000
        var cont: AsyncStream<HandQualityEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
        // Seed pending state so the first transition into NEAR_EDGE can fire
        // without needing a prior IN frame to set the dwell counter.
        leftState.pendingSinceNs = recordingStartMonotonicNs
        rightState.pendingSinceNs = recordingStartMonotonicNs
    }

    /// Per-frame entry point. Assigns observations to sides, drives the
    /// per-side state machine, writes interval records on transitions.
    ///
    /// The detector is configured for ``numHands = 2``, but the cardinality
    /// prior of egocentric capture (one left + one right at most) is
    /// enforced here too — anything past the first two observations is
    /// dropped before assignment. This protects the per-side cost matrix
    /// from a stray third detection (e.g. a bystander's hand catching the
    /// frame edge) pulling either side into the wrong status.
    public func ingest(observations: [HandObservation],
                       frame: Int,
                       monotonicNs: UInt64) async {
        guard config.enabled else { return }
        let capped = observations.count <= 2
            ? observations
            : Array(observations.prefix(2))
        let (leftObs, rightObs) = assignToSides(capped, monotonicNs: monotonicNs)
        await applySide(.left, observation: leftObs, frame: frame, monotonicNs: monotonicNs)
        await applySide(.right, observation: rightObs, frame: frame, monotonicNs: monotonicNs)
    }

    /// Close any open intervals at ``stopMonotonicNs``, finalize the writer,
    /// and end the public event stream.
    public func finalize(stopMonotonicNs: UInt64, stopFrame: Int) async {
        await closeIntervalsIfOpen(.left, monotonicNs: stopMonotonicNs, frame: stopFrame)
        await closeIntervalsIfOpen(.right, monotonicNs: stopMonotonicNs, frame: stopFrame)
        try? await eventWriter.finalize(stopMonotonicNs: stopMonotonicNs, stopFrame: stopFrame)
        continuation.finish()
    }

    /// Aggregate quality stats over the elapsed recording. Safe to call
    /// before ``finalize``; reflects state up to the last ingest.
    public func qualityStats(recordingStartMonotonicNs: UInt64,
                             stopMonotonicNs: UInt64) -> QualityStats {
        let durationNs = stopMonotonicNs &- recordingStartMonotonicNs
        let durationSec = Double(durationNs) / 1_000_000_000.0
        // If a side is currently OOF, attribute the open interval up to stopNs
        // so percentages don't lag the UI.
        var leftOofNs = leftState.oofAccumulatedNs
        var rightOofNs = rightState.oofAccumulatedNs
        if leftState.state == .outOfFrame {
            leftOofNs &+= (stopMonotonicNs &- leftState.lastOofStartNs)
        }
        if rightState.state == .outOfFrame {
            rightOofNs &+= (stopMonotonicNs &- rightState.lastOofStartNs)
        }
        let leftOofSec = Double(leftOofNs) / 1_000_000_000.0
        let rightOofSec = Double(rightOofNs) / 1_000_000_000.0
        let leftPct = durationSec > 0 ? max(0, 1 - leftOofSec / durationSec) : 1
        let rightPct = durationSec > 0 ? max(0, 1 - rightOofSec / durationSec) : 1
        let bothPct = min(leftPct, rightPct)
        return QualityStats(
            handInFramePct: bothPct,
            leftInFramePct: leftPct,
            rightInFramePct: rightPct,
            nearEdgeEventCount: leftState.nearEdgeCount + rightState.nearEdgeCount,
            outOfFrameEventCount: leftState.oofCount + rightState.oofCount,
            outOfFrameTotalSeconds: leftOofSec + rightOofSec,
            recordingDurationSeconds: durationSec
        )
    }

    // MARK: assignment

    /// Match observations to L/R sides using a weighted cost matrix that
    /// combines three signals — none of them load-bearing on its own:
    ///
    /// 1. **Chirality cost** (weight 1.0). MediaPipe's per-frame Left/
    ///    Right label, only trusted past ``chiralityConfidenceMin``.
    ///    Match → 0; mismatch above threshold → 1; below threshold → 0.5
    ///    (no signal). MediaPipe flips chirality between frames in
    ///    egocentric view often enough that this can never be a hard
    ///    gate; pairing it with the two signals below makes flips cost
    ///    more than they pay in score.
    /// 2. **Spatial cost** (weight 1.5 when memory fresh, 0 otherwise).
    ///    Normalized distance from this side's cached wrist to the
    ///    candidate observation's wrist, scaled to [0,1] over the
    ///    diagonal. Drops out completely when the side's wrist memory
    ///    has expired or never existed — preventing a stale anchor from
    ///    pulling a fresh observation onto the wrong side.
    /// 3. **Ego-cam position prior** (weight 0.4). In a chest- or head-
    ///    mounted ego camera the user's left wrist sits in the left
    ///    half of the (oriented) frame and the right wrist in the right
    ///    half. Soft preference: |wrist.x - 0.25| for left, |wrist.x -
    ///    0.75| for right. This is the tie-breaker that recovers the
    ///    correct identity when the wrist memory has been invalidated
    ///    (post-OOF) and chirality is uncertain — exactly the failure
    ///    mode the previous algorithm hit.
    private func assignToSides(_ obs: [HandObservation], monotonicNs: UInt64)
        -> (HandObservation?, HandObservation?) {
        if obs.isEmpty { return (nil, nil) }
        if obs.count == 1 {
            let o = obs[0]
            let cL = pairCost(o, side: .left, monotonicNs: monotonicNs)
            let cR = pairCost(o, side: .right, monotonicNs: monotonicNs)
            return cL <= cR ? (o, nil) : (nil, o)
        }
        let a = obs[0], b = obs[1]
        let pairAtoL = pairCost(a, side: .left, monotonicNs: monotonicNs)
                     + pairCost(b, side: .right, monotonicNs: monotonicNs)
        let pairAtoR = pairCost(a, side: .right, monotonicNs: monotonicNs)
                     + pairCost(b, side: .left, monotonicNs: monotonicNs)
        return pairAtoL <= pairAtoR ? (a, b) : (b, a)
    }

    private func pairCost(_ o: HandObservation,
                          side: HandSide,
                          monotonicNs: UInt64) -> Double {
        let s = (side == .left) ? leftState : rightState
        // Chirality cost.
        let chiralityCost: Double
        if let ch = o.chirality, o.chiralityConfidence >= config.chiralityConfidenceMin {
            chiralityCost = (ch == side) ? 0.0 : 1.0
        } else {
            chiralityCost = 0.5
        }
        // Spatial cost (only when wrist memory is fresh AND the candidate has a wrist).
        let spatialWeight: Double
        let spatialCost: Double
        if let lw = s.lastWrist,
           monotonicNs <= s.wristMemoryExpiresNs,
           let w = o.wrist {
            let d = distance(lw, w)
            spatialCost = min(1.0, d / 1.41421356)
            spatialWeight = 1.5
        } else {
            spatialCost = 0.0
            spatialWeight = 0.0
        }
        // Ego-cam prior. Soft preference toward left/right half by wrist x.
        let priorCost: Double
        if let w = o.wrist {
            let target: Double = (side == .left) ? 0.25 : 0.75
            priorCost = abs(w.x - target)   // range [0, 0.75]
        } else {
            priorCost = 0.5
        }
        return 1.0 * chiralityCost + spatialWeight * spatialCost + 0.4 * priorCost
    }

    private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    // MARK: per-side state machine

    private func applySide(_ side: HandSide,
                           observation: HandObservation?,
                           frame: Int,
                           monotonicNs: UInt64) async {
        let inGrace = monotonicNs < startupGraceUntilNs

        var s = (side == .left) ? leftState : rightState

        if let w = observation?.wrist {
            s.lastWrist = w
            s.wristMemoryExpiresNs = monotonicNs &+ UInt64(config.wristMemoryMs) * 1_000_000
            // Maintain the interior anchor: a fresh wrist that is deep
            // inside the frame refreshes the anchor; a fresh wrist that
            // has crossed into the edge zone clears it (the hand is on
            // its way out and edge-zone behavior should now drive OOF).
            updateInteriorAnchor(side: &s, wrist: w, monotonicNs: monotonicNs)
        } else if monotonicNs > s.wristMemoryExpiresNs {
            s.lastWrist = nil
        }
        // Independently expire the interior anchor by its own (longer) timer.
        if monotonicNs > s.interiorAnchorExpiresNs {
            s.lastInteriorWrist = nil
        }

        // Resolve instantaneous status using the (possibly-updated) cached
        // wrist so a missing observation backed by a fresh in-frame wrist
        // is treated as occlusion, not exit.
        let status = instantaneousStatus(observation: observation,
                                         sideState: s,
                                         monotonicNs: monotonicNs)

        // While in startup grace, don't transition. Just keep pendingState
        // tracking the latest status so the dwell counter is fresh when grace ends.
        if !inGrace {
            if status != s.pendingState {
                s.pendingState = status
                s.pendingSinceNs = monotonicNs
            }

            let dwellNs = monotonicNs &- s.pendingSinceNs
            let oofDebounceNs = UInt64(config.oofDebounceMs) * 1_000_000
            let recoveryDebounceNs = UInt64(config.recoveryDebounceMs) * 1_000_000

            switch (s.state, s.pendingState) {
            case (.inFrame, .nearEdge):
                // Eager — fire on first qualifying frame.
                await transition(side: side, sideState: &s, to: .nearEdge,
                                 monotonicNs: monotonicNs, frame: frame)
            case (.inFrame, .outOfFrame), (.nearEdge, .outOfFrame):
                if dwellNs >= oofDebounceNs {
                    await transition(side: side, sideState: &s, to: .outOfFrame,
                                     monotonicNs: monotonicNs, frame: frame)
                }
            case (.nearEdge, .inFrame):
                if dwellNs >= recoveryDebounceNs {
                    await transition(side: side, sideState: &s, to: .inFrame,
                                     monotonicNs: monotonicNs, frame: frame)
                }
            case (.outOfFrame, .inFrame):
                if dwellNs >= recoveryDebounceNs {
                    await transition(side: side, sideState: &s, to: .inFrame,
                                     monotonicNs: monotonicNs, frame: frame)
                }
            case (.outOfFrame, .nearEdge):
                if dwellNs >= recoveryDebounceNs {
                    await transition(side: side, sideState: &s, to: .nearEdge,
                                     monotonicNs: monotonicNs, frame: frame)
                }
            default:
                break
            }
        } else {
            // During grace, still track pending so dwell starts counting
            // immediately when grace ends.
            if status != s.pendingState {
                s.pendingState = status
                s.pendingSinceNs = monotonicNs
            }
        }

        if side == .left { leftState = s } else { rightState = s }
    }

    /// Refresh or invalidate the interior anchor based on a fresh wrist.
    ///
    /// The interior anchor is the FP-cue suppression knob: it pins the
    /// side to ``inFrame`` for the duration of
    /// ``HandQualityConfig/interiorAnchorHoldMs`` after the last
    /// confident interior detection, so an occlusion / off-axis pose /
    /// motion-blur stack that drops the detector for several seconds
    /// does not fire a false-positive OOF audio cue.
    ///
    /// Refresh policy: if the wrist is at least
    /// ``interiorAnchorMarginNorm`` from every edge → refresh anchor
    /// (this wrist is unambiguously interior). Otherwise → clear the
    /// anchor; the hand has crossed into the edge band and the
    /// existing edge-zone behavior should govern OOF.
    private func updateInteriorAnchor(side s: inout SideState,
                                      wrist w: SIMD2<Double>,
                                      monotonicNs: UInt64) {
        // Interior anchor is gated by both knobs:
        //   - ``interiorAnchorHoldMs == 0``  → feature explicitly disabled
        //   - ``occlusionHoldEnabled == false`` → master "no drop suppression"
        //     switch (kept consistent with the legacy edge-zone hold so tests
        //     that flip the master switch still see raw OOF accounting)
        guard config.interiorAnchorHoldMs > 0,
              config.occlusionHoldEnabled else {
            s.lastInteriorWrist = nil
            s.interiorAnchorExpiresNs = 0
            return
        }
        let margin = config.interiorAnchorMarginNorm
        let isInterior =
            w.x >= margin && w.x <= 1 - margin &&
            w.y >= margin && w.y <= 1 - margin
        if isInterior {
            s.lastInteriorWrist = w
            s.interiorAnchorExpiresNs = monotonicNs
                &+ UInt64(config.interiorAnchorHoldMs) * 1_000_000
        } else {
            s.lastInteriorWrist = nil
            s.interiorAnchorExpiresNs = 0
        }
    }

    /// Wrist-centric instantaneous status.
    ///
    /// Manipulation-heavy egocentric video frequently produces partial
    /// hand observations: fingers tucked into a grip, one hand occluded
    /// by the other, the wrist plus a couple of palm-base joints visible
    /// but most fingertip landmarks gone. The bbox-extent rule the
    /// previous logic used would either reject those observations
    /// outright (via ``minConfidentKeypointsForBbox``) or compute a tiny
    /// jittery bbox that flickered against the proximity threshold.
    ///
    /// Instead, judge from a single representative anchor point, in this
    /// priority order:
    /// 1. Prefer the observation's wrist (landmark 0 — last to be
    ///    occluded during grasp).
    /// 2. Fall back to the centroid of confident keypoints when wrist is
    ///    missing but at least one keypoint survived.
    /// 3. **Interior anchor (egocentric FP-cue suppression)**: when the
    ///    detector returned nothing but a recent *interior-zone* wrist is
    ///    still within its hold window, force ``inFrame``. This suppresses
    ///    the false-positive audio cue that would otherwise fire when a
    ///    cylindrical grip / off-axis pose drops the detector for several
    ///    seconds even though the hand is physically still in view.
    /// 4. Edge-zone occlusion-hold: when the detector returned nothing
    ///    and only a short-lived edge-zone wrist is cached, the hand was
    ///    on its way out — return ``outOfFrame`` immediately.
    /// 5. Otherwise the hand is genuinely gone — ``outOfFrame``.
    private func instantaneousStatus(observation obs: HandObservation?,
                                     sideState s: SideState,
                                     monotonicNs: UInt64) -> State {
        let m = config.proximityWarningExtentNorm

        if let o = obs {
            if let w = o.wrist {
                return classify(point: w, edgeMargin: m)
            }
            if !o.confidentKeypoints.isEmpty {
                let cx = o.confidentKeypoints.map(\.x).reduce(0, +)
                    / Double(o.confidentKeypoints.count)
                let cy = o.confidentKeypoints.map(\.y).reduce(0, +)
                    / Double(o.confidentKeypoints.count)
                return classify(point: SIMD2(cx, cy), edgeMargin: m)
            }
            return .outOfFrame
        }

        // No fresh observation. Interior anchor takes precedence over the
        // shorter assignment-side wrist memory: a hand last seen deep in
        // the interior is overwhelmingly likely still there but occluded.
        // Gated by both ``interiorAnchorHoldMs > 0`` and
        // ``occlusionHoldEnabled`` — see ``updateInteriorAnchor`` for the
        // rationale on tying the two switches together.
        if config.interiorAnchorHoldMs > 0,
           config.occlusionHoldEnabled,
           s.lastInteriorWrist != nil,
           monotonicNs <= s.interiorAnchorExpiresNs {
            return .inFrame
        }

        // Fall through to the existing edge-zone occlusion-hold path.
        guard config.occlusionHoldEnabled,
              let lw = s.lastWrist,
              monotonicNs <= s.wristMemoryExpiresNs else {
            return .outOfFrame
        }
        // If the last known wrist was already at the very edge, the hand
        // was on its way out — let the OOF debounce run normally.
        let exit = config.edgeExitMargin
        if lw.x < exit || lw.x > 1 - exit || lw.y < exit || lw.y > 1 - exit {
            return .outOfFrame
        }
        return classify(point: lw, edgeMargin: m)
    }

    private func classify(point p: SIMD2<Double>, edgeMargin m: Double) -> State {
        // Clamp out-of-unit points (rare but possible from oriented
        // landmarks); a wrist that lies outside [0,1]² is genuinely off-frame.
        if p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1 { return .outOfFrame }
        let near = p.x < m || p.x > 1 - m || p.y < m || p.y > 1 - m
        return near ? .nearEdge : .inFrame
    }

    // MARK: transitions

    private func transition(side: HandSide,
                            sideState s: inout SideState,
                            to newState: State,
                            monotonicNs: UInt64,
                            frame: Int) async {
        let old = s.state
        s.state = newState

        if old == .nearEdge, let h = s.openNearEdgeHandle {
            try? await eventWriter.closeInterval(handle: h,
                                                 endMonotonicNs: monotonicNs,
                                                 endFrame: frame)
            s.openNearEdgeHandle = nil
            s.nearEdgeAccumulatedNs &+= (monotonicNs &- s.lastNearEdgeStartNs)
            continuation.yield(.nearEdgeEnd(side: side, monotonicNs: monotonicNs, frame: frame))
        }
        if old == .outOfFrame, let h = s.openOofHandle {
            try? await eventWriter.closeInterval(handle: h,
                                                 endMonotonicNs: monotonicNs,
                                                 endFrame: frame)
            s.openOofHandle = nil
            s.oofAccumulatedNs &+= (monotonicNs &- s.lastOofStartNs)
            continuation.yield(.outOfFrameEnd(side: side, monotonicNs: monotonicNs, frame: frame))
        }
        if newState == .nearEdge {
            let h = try? await eventWriter.appendIntervalStart(
                kind: "hand_near_edge",
                startMonotonicNs: monotonicNs,
                startFrame: frame,
                payload: ["hand": side.rawValue]
            )
            s.openNearEdgeHandle = h
            s.lastNearEdgeStartNs = monotonicNs
            s.nearEdgeCount += 1
            continuation.yield(.nearEdgeStart(side: side, edges: [],
                                              monotonicNs: monotonicNs, frame: frame))
        }
        if newState == .outOfFrame {
            let h = try? await eventWriter.appendIntervalStart(
                kind: "hand_out_of_frame",
                startMonotonicNs: monotonicNs,
                startFrame: frame,
                payload: ["hand": side.rawValue]
            )
            s.openOofHandle = h
            s.lastOofStartNs = monotonicNs
            s.oofCount += 1
            // Invalidate the cached wrist when entering OOF. The
            // assignment cost matrix would otherwise keep pulling fresh
            // observations toward this side's stale anchor, even though
            // the side is no longer "tracked". Identity is re-established
            // either by chirality (when MediaPipe is confident) or by the
            // ego-cam position prior on the next frame.
            s.lastWrist = nil
            s.wristMemoryExpiresNs = 0
            // Same reasoning for the interior anchor: once the side has
            // been declared OOF, any future re-acquisition starts fresh
            // and must not be suppressed by a stale interior position.
            s.lastInteriorWrist = nil
            s.interiorAnchorExpiresNs = 0
            continuation.yield(.outOfFrameStart(side: side,
                                                monotonicNs: monotonicNs, frame: frame))
        }
    }

    private func closeIntervalsIfOpen(_ side: HandSide, monotonicNs: UInt64, frame: Int) async {
        var s = (side == .left) ? leftState : rightState
        if let h = s.openNearEdgeHandle {
            try? await eventWriter.closeInterval(handle: h,
                                                 endMonotonicNs: monotonicNs,
                                                 endFrame: frame)
            s.openNearEdgeHandle = nil
            s.nearEdgeAccumulatedNs &+= (monotonicNs &- s.lastNearEdgeStartNs)
            continuation.yield(.nearEdgeEnd(side: side, monotonicNs: monotonicNs, frame: frame))
        }
        if let h = s.openOofHandle {
            try? await eventWriter.closeInterval(handle: h,
                                                 endMonotonicNs: monotonicNs,
                                                 endFrame: frame)
            s.openOofHandle = nil
            s.oofAccumulatedNs &+= (monotonicNs &- s.lastOofStartNs)
            continuation.yield(.outOfFrameEnd(side: side, monotonicNs: monotonicNs, frame: frame))
        }
        if side == .left { leftState = s } else { rightState = s }
    }
}
