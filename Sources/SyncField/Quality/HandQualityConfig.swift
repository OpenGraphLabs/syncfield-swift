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
                verdictRejectThreshold: Double = 0.80) {
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
    }
}
