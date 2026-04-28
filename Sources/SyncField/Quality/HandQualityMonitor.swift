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
    public func ingest(observations: [HandObservation],
                       frame: Int,
                       monotonicNs: UInt64) async {
        guard config.enabled else { return }
        let (leftObs, rightObs) = assignToSides(observations, monotonicNs: monotonicNs)
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

    private func assignToSides(_ obs: [HandObservation], monotonicNs: UInt64)
        -> (HandObservation?, HandObservation?) {
        // Try chirality first when confident enough.
        let allConfidentChirality = obs.allSatisfy {
            $0.chirality != nil && $0.chiralityConfidence >= config.chiralityConfidenceMin
        }
        if allConfidentChirality && !obs.isEmpty {
            let l = obs.first(where: { $0.chirality == .left })
            let r = obs.first(where: { $0.chirality == .right })
            return (l, r)
        }
        // Spatial-continuity fallback
        guard config.spatialContinuityFallback else { return (nil, nil) }
        if obs.isEmpty { return (nil, nil) }
        if obs.count == 1 {
            let one = obs[0]
            if let ch = one.chirality, one.chiralityConfidence >= config.chiralityConfidenceMin {
                return ch == .left ? (one, nil) : (nil, one)
            }
            if let w = one.wrist {
                let dl = leftState.lastWrist.map { distance($0, w) } ?? .infinity
                let dr = rightState.lastWrist.map { distance($0, w) } ?? .infinity
                return dl < dr ? (one, nil) : (nil, one)
            }
            return (nil, nil)
        }
        // 2 observations, both with chirality unknown / low confidence.
        let a = obs[0], b = obs[1]
        let aw = a.wrist ?? .zero
        let bw = b.wrist ?? .zero
        let lastL = leftState.lastWrist
        let lastR = rightState.lastWrist
        let costAtoL = lastL.map { distance($0, aw) } ?? 1.0
        let costAtoR = lastR.map { distance($0, aw) } ?? 1.0
        let costBtoL = lastL.map { distance($0, bw) } ?? 1.0
        let costBtoR = lastR.map { distance($0, bw) } ?? 1.0
        if (costAtoL + costBtoR) <= (costAtoR + costBtoL) {
            return (a, b)
        } else {
            return (b, a)
        }
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
        let status = instantaneousStatus(for: observation)

        var s = (side == .left) ? leftState : rightState

        if let w = observation?.wrist {
            s.lastWrist = w
            s.wristMemoryExpiresNs = monotonicNs &+ UInt64(config.wristMemoryMs) * 1_000_000
        } else if monotonicNs > s.wristMemoryExpiresNs {
            s.lastWrist = nil
        }

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

    private func instantaneousStatus(for obs: HandObservation?) -> State {
        guard let o = obs else { return .outOfFrame }
        guard o.confidentKeypoints.count >= config.minConfidentKeypointsForBbox else {
            return .outOfFrame
        }
        let xs = o.confidentKeypoints.map { $0.x }
        let ys = o.confidentKeypoints.map { $0.y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let m = config.proximityWarningExtentNorm
        let near = minX < m || maxX > 1 - m || minY < m || maxY > 1 - m
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
