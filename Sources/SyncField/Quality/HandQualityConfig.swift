// Sources/SyncField/Quality/HandQualityConfig.swift
import Foundation

/// Tunable thresholds for the hand FOV quality monitor.
///
/// Defaults are picked for a chest/head-mounted iPhone running Apple
/// Vision hand-pose at 10 Hz. Field testing may shift the proximity
/// threshold or the OOF debounce; everything is exposed so host apps
/// can override per session.
public struct HandQualityConfig: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var proximityWarningExtentNorm: Double
    public var oofDebounceMs: Int
    public var recoveryDebounceMs: Int
    public var minKeypointConfidence: Double
    public var minConfidentKeypointsForBbox: Int
    public var spatialContinuityFallback: Bool
    public var chiralityConfidenceMin: Double
    public var wristMemoryMs: Int
    public var startupGraceMs: Int
    public var verdictGoodThreshold: Double
    public var verdictRejectThreshold: Double
    /// When the detector returns no observation for a side but a recent
    /// wrist position is still cached (within ``wristMemoryMs``) and that
    /// wrist sat well inside the frame, treat the missing observation as
    /// an occlusion rather than an exit. Distance from the edge (in
    /// normalized units) below which a stale wrist is treated as
    /// ``nearEdge`` rather than ``inFrame`` is governed by
    /// ``proximityWarningExtentNorm``; once the stale wrist is closer than
    /// ``edgeExitMargin`` to any edge, occlusion-hold no longer applies and
    /// the missing observation flows through to OOF.
    public var occlusionHoldEnabled: Bool
    /// If a stale wrist is within this normalized distance of any frame
    /// edge, occlusion-hold does NOT apply (the hand was on its way out).
    public var edgeExitMargin: Double
    /// **Egocentric interior anchor** (FP-cue suppression).
    ///
    /// In a chest- or head-mounted ego camera the user's hands almost
    /// always traverse the frame edge before truly leaving. A detection
    /// drop while the last confident wrist was deep inside the frame is
    /// therefore overwhelmingly likely to be occlusion (cylindrical grip,
    /// off-axis pose, motion blur), not a real exit. The interior anchor
    /// is a separate, longer-lived hold that pins a side to ``inFrame``
    /// while its last interior wrist is still fresh.
    ///
    /// Distinct from ``occlusionHoldEnabled`` / ``wristMemoryMs``, which
    /// hold a wrist for the *side-assignment* cost matrix and run on a
    /// shorter clock. The interior anchor only governs the per-side
    /// ``inFrame`` / ``outOfFrame`` decision.
    ///
    /// Set ``interiorAnchorHoldMs`` to 0 to disable.
    public var interiorAnchorMarginNorm: Double
    /// How long to hold ``inFrame`` after the last interior-zone wrist
    /// detection if no further observation arrives. Set to 0 to disable
    /// the interior anchor entirely (legacy behavior).
    ///
    /// Defaults to 8000 ms — long enough to absorb multi-second grip /
    /// occlusion stacks observed in the seed clip
    /// (`docs/egocentric-hand-oof-rnd/RESULTS-round-1.md`), short enough
    /// that a hand truly removed from view for >8 s still produces an
    /// OOF event for downstream quality scoring.
    public var interiorAnchorHoldMs: Int

    public init(enabled: Bool = true,
                proximityWarningExtentNorm: Double = 0.10,
                oofDebounceMs: Int = 200,
                recoveryDebounceMs: Int = 100,
                minKeypointConfidence: Double = 0.3,
                minConfidentKeypointsForBbox: Int = 5,
                spatialContinuityFallback: Bool = true,
                chiralityConfidenceMin: Double = 0.7,
                wristMemoryMs: Int = 1500,
                startupGraceMs: Int = 1000,
                verdictGoodThreshold: Double = 0.95,
                verdictRejectThreshold: Double = 0.80,
                occlusionHoldEnabled: Bool = true,
                edgeExitMargin: Double = 0.05,
                interiorAnchorMarginNorm: Double = 0.20,
                interiorAnchorHoldMs: Int = 8000) {
        self.enabled = enabled
        self.proximityWarningExtentNorm = proximityWarningExtentNorm
        self.oofDebounceMs = oofDebounceMs
        self.recoveryDebounceMs = recoveryDebounceMs
        self.minKeypointConfidence = minKeypointConfidence
        self.minConfidentKeypointsForBbox = minConfidentKeypointsForBbox
        self.spatialContinuityFallback = spatialContinuityFallback
        self.chiralityConfidenceMin = chiralityConfidenceMin
        self.wristMemoryMs = wristMemoryMs
        self.startupGraceMs = startupGraceMs
        self.verdictGoodThreshold = verdictGoodThreshold
        self.verdictRejectThreshold = verdictRejectThreshold
        self.occlusionHoldEnabled = occlusionHoldEnabled
        self.edgeExitMargin = edgeExitMargin
        self.interiorAnchorMarginNorm = interiorAnchorMarginNorm
        self.interiorAnchorHoldMs = interiorAnchorHoldMs
    }

    public static let `default` = HandQualityConfig()

    enum CodingKeys: String, CodingKey {
        case enabled
        case proximityWarningExtentNorm = "proximity_warning_extent_norm"
        case oofDebounceMs = "oof_debounce_ms"
        case recoveryDebounceMs = "recovery_debounce_ms"
        case minKeypointConfidence = "min_keypoint_confidence"
        case minConfidentKeypointsForBbox = "min_confident_keypoints_for_bbox"
        case spatialContinuityFallback = "spatial_continuity_fallback"
        case chiralityConfidenceMin = "chirality_confidence_min"
        case wristMemoryMs = "wrist_memory_ms"
        case startupGraceMs = "startup_grace_ms"
        case verdictGoodThreshold = "verdict_good_threshold"
        case verdictRejectThreshold = "verdict_reject_threshold"
        case occlusionHoldEnabled = "occlusion_hold_enabled"
        case edgeExitMargin = "edge_exit_margin"
        case interiorAnchorMarginNorm = "interior_anchor_margin_norm"
        case interiorAnchorHoldMs = "interior_anchor_hold_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.proximityWarningExtentNorm = try c.decodeIfPresent(
            Double.self, forKey: .proximityWarningExtentNorm) ?? 0.10
        self.oofDebounceMs = try c.decodeIfPresent(Int.self, forKey: .oofDebounceMs) ?? 200
        self.recoveryDebounceMs = try c.decodeIfPresent(Int.self, forKey: .recoveryDebounceMs) ?? 100
        self.minKeypointConfidence = try c.decodeIfPresent(
            Double.self, forKey: .minKeypointConfidence) ?? 0.3
        self.minConfidentKeypointsForBbox = try c.decodeIfPresent(
            Int.self, forKey: .minConfidentKeypointsForBbox) ?? 5
        self.spatialContinuityFallback = try c.decodeIfPresent(
            Bool.self, forKey: .spatialContinuityFallback) ?? true
        self.chiralityConfidenceMin = try c.decodeIfPresent(
            Double.self, forKey: .chiralityConfidenceMin) ?? 0.7
        self.wristMemoryMs = try c.decodeIfPresent(Int.self, forKey: .wristMemoryMs) ?? 1500
        self.startupGraceMs = try c.decodeIfPresent(Int.self, forKey: .startupGraceMs) ?? 1000
        self.verdictGoodThreshold = try c.decodeIfPresent(
            Double.self, forKey: .verdictGoodThreshold) ?? 0.95
        self.verdictRejectThreshold = try c.decodeIfPresent(
            Double.self, forKey: .verdictRejectThreshold) ?? 0.80
        self.occlusionHoldEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .occlusionHoldEnabled) ?? true
        self.edgeExitMargin = try c.decodeIfPresent(Double.self, forKey: .edgeExitMargin) ?? 0.05
        self.interiorAnchorMarginNorm = try c.decodeIfPresent(
            Double.self, forKey: .interiorAnchorMarginNorm) ?? 0.20
        self.interiorAnchorHoldMs = try c.decodeIfPresent(
            Int.self, forKey: .interiorAnchorHoldMs) ?? 8000
    }
}
