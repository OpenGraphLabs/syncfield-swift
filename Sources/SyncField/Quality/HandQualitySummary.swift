// Sources/SyncField/Quality/HandQualitySummary.swift
import Foundation

/// JSON-serializable per-recording quality summary written to
/// `<episode>/hand_quality.json` at session finalize.
///
/// Schema mirrors the existing `egomotion_quality.json` layout used by
/// the dashboard so the same `EgomotionQualityBadge`-style presentation
/// works for hand-quality with no special-casing on the web side.
public struct HandQualitySummary: Sendable, Equatable, Codable {
    public enum Verdict: String, Sendable, Codable {
        case good, marginal, reject
    }

    public struct SubScores: Sendable, Equatable, Codable {
        public let leftInFramePct: Double
        public let rightInFramePct: Double
        public let bothInFramePct: Double

        public init(leftInFramePct: Double, rightInFramePct: Double, bothInFramePct: Double) {
            self.leftInFramePct = leftInFramePct
            self.rightInFramePct = rightInFramePct
            self.bothInFramePct = bothInFramePct
        }

        enum CodingKeys: String, CodingKey {
            case leftInFramePct = "left_in_frame_pct"
            case rightInFramePct = "right_in_frame_pct"
            case bothInFramePct = "both_in_frame_pct"
        }
    }

    public struct Thresholds: Sendable, Equatable, Codable {
        public let good: Double
        public let reject: Double

        public init(good: Double, reject: Double) {
            self.good = good
            self.reject = reject
        }
    }

    public let verdict: Verdict
    public let overallScore: Double
    public let subScores: SubScores
    public let raw: QualityStats
    public let thresholds: Thresholds
    public let config: HandQualityConfig

    public init(verdict: Verdict,
                overallScore: Double,
                subScores: SubScores,
                raw: QualityStats,
                thresholds: Thresholds,
                config: HandQualityConfig) {
        self.verdict = verdict
        self.overallScore = overallScore
        self.subScores = subScores
        self.raw = raw
        self.thresholds = thresholds
        self.config = config
    }

    enum CodingKeys: String, CodingKey {
        case verdict
        case overallScore = "overall_score"
        case subScores = "sub_scores"
        case raw, thresholds, config
    }
}

/// Convenience namespace for building a ``HandQualitySummary`` from a
/// raw ``QualityStats`` and writing it to disk.
public enum HandQualitySummaryBuilder {
    public static func build(stats: QualityStats, config: HandQualityConfig) -> HandQualitySummary {
        let overall = stats.handInFramePct
        let v: HandQualitySummary.Verdict = {
            if overall >= config.verdictGoodThreshold { return .good }
            if overall < config.verdictRejectThreshold { return .reject }
            return .marginal
        }()
        return HandQualitySummary(
            verdict: v,
            overallScore: overall,
            subScores: .init(
                leftInFramePct: stats.leftInFramePct,
                rightInFramePct: stats.rightInFramePct,
                bothInFramePct: stats.handInFramePct
            ),
            raw: stats,
            thresholds: .init(good: config.verdictGoodThreshold,
                              reject: config.verdictRejectThreshold),
            config: config
        )
    }

    public static func write(_ summary: HandQualitySummary, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(summary).write(to: url, options: .atomic)
    }
}
