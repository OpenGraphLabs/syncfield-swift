// Sources/SyncField/Quality/HandQualityTypes.swift
import Foundation

/// Side of the body. Used to attribute hand-quality events to a specific hand.
public enum HandSide: String, Sendable, Codable, CaseIterable {
    case left
    case right
}

/// Which edge of the camera frame a near-edge transition is approaching.
public enum FrameEdge: String, Sendable, Codable, CaseIterable {
    case left
    case right
    case top
    case bottom
}

/// Per-hand state-machine transition emitted by ``HandQualityMonitor``.
public enum HandQualityEvent: Sendable, Equatable {
    case nearEdgeStart(side: HandSide, edges: Set<FrameEdge>, monotonicNs: UInt64, frame: Int)
    case nearEdgeEnd(side: HandSide, monotonicNs: UInt64, frame: Int)
    case outOfFrameStart(side: HandSide, monotonicNs: UInt64, frame: Int)
    case outOfFrameEnd(side: HandSide, monotonicNs: UInt64, frame: Int)

    public var side: HandSide {
        switch self {
        case .nearEdgeStart(let s, _, _, _),
             .nearEdgeEnd(let s, _, _),
             .outOfFrameStart(let s, _, _),
             .outOfFrameEnd(let s, _, _):
            return s
        }
    }

    public var monotonicNs: UInt64 {
        switch self {
        case .nearEdgeStart(_, _, let ns, _),
             .nearEdgeEnd(_, let ns, _),
             .outOfFrameStart(_, let ns, _),
             .outOfFrameEnd(_, let ns, _):
            return ns
        }
    }
}

/// Aggregate quality numbers for a finished recording. Computed by
/// ``HandQualityMonitor/qualityStats(recordingStartMonotonicNs:stopMonotonicNs:)``
/// and embedded into `hand_quality.json`.
public struct QualityStats: Sendable, Equatable, Codable {
    public let handInFramePct: Double
    public let leftInFramePct: Double
    public let rightInFramePct: Double
    public let nearEdgeEventCount: Int
    public let outOfFrameEventCount: Int
    public let outOfFrameTotalSeconds: Double
    public let recordingDurationSeconds: Double

    public init(handInFramePct: Double,
                leftInFramePct: Double,
                rightInFramePct: Double,
                nearEdgeEventCount: Int,
                outOfFrameEventCount: Int,
                outOfFrameTotalSeconds: Double,
                recordingDurationSeconds: Double) {
        self.handInFramePct = handInFramePct
        self.leftInFramePct = leftInFramePct
        self.rightInFramePct = rightInFramePct
        self.nearEdgeEventCount = nearEdgeEventCount
        self.outOfFrameEventCount = outOfFrameEventCount
        self.outOfFrameTotalSeconds = outOfFrameTotalSeconds
        self.recordingDurationSeconds = recordingDurationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case handInFramePct = "hand_in_frame_pct"
        case leftInFramePct = "left_in_frame_pct"
        case rightInFramePct = "right_in_frame_pct"
        case nearEdgeEventCount = "near_edge_event_count"
        case outOfFrameEventCount = "out_of_frame_event_count"
        case outOfFrameTotalSeconds = "out_of_frame_total_seconds"
        case recordingDurationSeconds = "recording_duration_seconds"
    }
}
