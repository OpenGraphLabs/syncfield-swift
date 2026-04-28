// Sources/SyncField/Quality/VisionHandConversion.swift
//
// Converts Apple Vision's `VNHumanHandPoseObservation` into the SDK's
// portable, test-friendly `HandObservation` value type. Lives behind a
// canImport guard so the core SDK stays buildable on platforms (e.g.
// macOS unit tests) where Vision isn't on the import path the way it is
// on iOS — even though Vision IS available on macOS, we keep the guard
// for tooling friendliness with Linux CI down the line.

#if canImport(Vision)
import Foundation
import Vision

extension HandObservation {
    /// Convert a `VNHumanHandPoseObservation` to the SDK's portable
    /// representation. Keypoints below ``minConfidence`` are filtered.
    /// Returns nil if the observation has no recognized points at all.
    public static func from(vision o: VNHumanHandPoseObservation,
                            minConfidence: Double) -> HandObservation? {
        let chirality: HandSide?
        switch o.chirality {
        case .left:    chirality = .left
        case .right:   chirality = .right
        case .unknown: chirality = nil
        @unknown default: chirality = nil
        }
        let chiralityConf = Double(o.confidence)

        guard let pts = try? o.recognizedPoints(.all) else { return nil }
        var confident: [SIMD2<Double>] = []
        var wrist: SIMD2<Double>? = nil
        for (joint, p) in pts where Double(p.confidence) >= minConfidence {
            let pt = SIMD2(Double(p.location.x), Double(p.location.y))
            confident.append(pt)
            if joint == .wrist {
                wrist = pt
            }
        }
        return HandObservation(
            chirality: chirality,
            chiralityConfidence: chiralityConf,
            confidentKeypoints: confident,
            wrist: wrist
        )
    }
}
#endif
