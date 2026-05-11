// Sources/SyncField/Audio/CountdownTickPlayer.swift
import Foundation

#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// Plays the per-tick tone for an audible `CountdownSpec`.
///
/// Backed by `AVAudioPlayer` (one pre-loaded player per tick index), not
/// `AVAudioEngine`. The chirp player downstream is also an `AVAudioEngine`
/// instance, and running two engines side by side has been observed in
/// the field to make the second engine return software-only fallback
/// emission (silent chirp) because of audio-hardware contention.
/// `AVAudioPlayer` is a higher-level API that doesn't try to own the
/// engine graph, so it coexists cleanly with the chirp player.
///
/// Tones are pre-rendered as in-memory WAV blobs on first use and re-used
/// across recordings, so every tick has zero generation latency in the
/// hot path. Playback routes through whatever `AVAudioSession` is active,
/// which `SessionOrchestrator.connect()` has set to play-and-record with
/// `.defaultToSpeaker`, so the tone always exits the iPhone main speaker.
public final class CountdownTickPlayer: @unchecked Sendable {
    public init() {}

    /// Frequencies (Hz) for tick indexes 0..2 (ascending). Index 0 is
    /// the FIRST tick the user hears (i.e. "3" in a 3-2-1 countdown).
    /// Validated in og-skill production: 880, 1047, 1175 (A5, C6, D6)
    /// cuts through head-mount placement without sounding like a chirp.
    public static let toneFrequencies: [Double] = [880, 1047, 1175]
    public static let toneDurationSec: Double = 0.11
    public static let toneAmplitude: Float = 0.9
    public static let sampleRate: Double = 44100

    /// Synchronously play the tone for `tickIndex` (0 = first tick).
    /// Returns immediately after scheduling. Safe to call from any actor
    /// or queue.
    public func play(tickIndex: Int) {
        #if canImport(AVFoundation) && os(iOS)
        playOnAVAudioPlayer(tickIndex: tickIndex)
        #endif
    }

    // MARK: - Private

    #if canImport(AVFoundation) && os(iOS)
    private let lock = NSLock()
    private var cachedPlayers: [Int: AVAudioPlayer] = [:]

    private func playOnAVAudioPlayer(tickIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        let player = ensurePlayer(forTickIndex: tickIndex)
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private func ensurePlayer(forTickIndex tickIndex: Int) -> AVAudioPlayer? {
        if let cached = cachedPlayers[tickIndex] { return cached }
        let freqs = Self.toneFrequencies
        let freq = freqs[min(tickIndex, freqs.count - 1)]
        let samples = ToneSynthesis.render(
            frequencyHz: freq,
            durationSec: Self.toneDurationSec,
            amplitude: Self.toneAmplitude,
            envelopeMs: 8,
            sampleRate: Self.sampleRate)
        let wav = WAVWriter.encodePCM16Mono(samples: samples,
                                             sampleRate: Self.sampleRate)
        do {
            let p = try AVAudioPlayer(data: wav)
            p.volume = 1.0
            p.prepareToPlay()
            cachedPlayers[tickIndex] = p
            return p
        } catch {
            NSLog("[CountdownTickPlayer] AVAudioPlayer init failed: \(error)")
            return nil
        }
    }
    #endif
}

/// Pure waveform generator for short countdown tones. Plain sine with a
/// short raised-cosine envelope so the cue doesn't click at speaker
/// onset / offset. Lives outside `ChirpSynthesis` because tones are a
/// single frequency, not a sweep.
public enum ToneSynthesis {
    public static func render(
        frequencyHz: Double,
        durationSec: Double,
        amplitude: Float,
        envelopeMs: Double,
        sampleRate: Double
    ) -> [Float] {
        let frameCount = Int(durationSec * sampleRate)
        guard frameCount > 0 else { return [] }
        let envFrames = max(0, Int(envelopeMs / 1000 * sampleRate))
        var out = [Float](repeating: 0, count: frameCount)
        let twoPiF = 2.0 * Double.pi * frequencyHz / sampleRate
        for i in 0..<frameCount {
            let env: Float
            if i < envFrames {
                let t = Double(i) / Double(max(1, envFrames))
                env = Float(0.5 * (1.0 - cos(Double.pi * t)))
            } else if i > frameCount - envFrames {
                let t = Double(frameCount - i) / Double(max(1, envFrames))
                env = Float(0.5 * (1.0 - cos(Double.pi * t)))
            } else {
                env = 1.0
            }
            out[i] = Float(sin(twoPiF * Double(i))) * amplitude * env
        }
        return out
    }
}

/// Minimal in-memory WAV writer (PCM 16-bit, mono). Used by
/// `CountdownTickPlayer` so the per-tick tone is loadable through
/// `AVAudioPlayer.init(data:)` without a temp file.
public enum WAVWriter {
    public static func encodePCM16Mono(samples: [Float], sampleRate: Double) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * channels * bitsPerSample / 8
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(u32(UInt32(chunkSize)))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.append(u32(16))                        // fmt chunk size
        data.append(u16(1))                         // PCM
        data.append(u16(UInt16(channels)))
        data.append(u32(UInt32(sampleRate)))
        data.append(u32(UInt32(byteRate)))
        data.append(u16(UInt16(blockAlign)))
        data.append(u16(UInt16(bitsPerSample)))

        data.append(contentsOf: Array("data".utf8))
        data.append(u32(UInt32(dataSize)))

        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let pcm = Int16(clipped * Float(Int16.max))
            data.append(u16(UInt16(bitPattern: pcm)))
        }
        return data
    }

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }

    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }
}
