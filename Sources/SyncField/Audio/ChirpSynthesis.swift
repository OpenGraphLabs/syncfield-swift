// Sources/SyncField/Audio/ChirpSynthesis.swift
import Foundation

/// Pure-function renderer for a linear FM sweep with cosine envelope.
/// Matches Python syncfield/tone.py:71 exactly.
public enum ChirpSynthesis {
    public static func render(_ spec: ChirpSpec, sampleRate: Double) -> [Float] {
        let durationS = spec.durationMs / 1000.0
        let n = Int(durationS * sampleRate)
        guard n > 0 else { return [] }

        let f0 = spec.fromHz
        let f1 = spec.toHz
        let k  = (f1 - f0) / durationS  // sweep rate Hz/s
        let envS = spec.envelopeMs / 1000.0
        let envN = max(1, Int(envS * sampleRate))
        let amp  = Float(spec.amplitude)

        var out = [Float](repeating: 0, count: n)
        let twoPi = 2.0 * Double.pi
        for i in 0..<n {
            let t = Double(i) / sampleRate
            // Linear FM: phase(t) = 2π(f0·t + 0.5·k·t²)
            let phase = twoPi * (f0 * t + 0.5 * k * t * t)
            var sample = Float(sin(phase)) * amp

            // Cosine attack + release envelope
            if i < envN {
                let a = 0.5 * (1.0 - cos(.pi * Double(i) / Double(envN)))
                sample *= Float(a)
            } else if i >= n - envN {
                let tail = Double(n - 1 - i) / Double(envN)
                let a = 0.5 * (1.0 - cos(.pi * tail))
                sample *= Float(a)
            }
            out[i] = sample
        }
        return out
    }
}
