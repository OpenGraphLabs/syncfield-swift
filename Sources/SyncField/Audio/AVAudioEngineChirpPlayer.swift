// Sources/SyncField/Audio/AVAudioEngineChirpPlayer.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// iOS/macOS default chirp player. Synthesizes the waveform, schedules
/// it through `AVAudioEngine`, and captures `AVAudioTime.hostTime` as
/// the hardware-anchored emission timestamp.
public final class AVAudioEngineChirpPlayer: ChirpPlayer, @unchecked Sendable {
    public init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    public var isSilent: Bool { false }

    public func play(_ spec: ChirpSpec) async -> ChirpEmission {
        #if canImport(AVFoundation)
        let samples = ChirpSynthesis.render(spec, sampleRate: sampleRate)
        guard !samples.isEmpty else {
            return ChirpEmission(softwareNs: currentMonotonicNs(),
                                 hardwareNs: nil, source: .softwareFallback)
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                            options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* ignore session errors; engine.start() will fail gracefully below */ }
        #endif

        do { try engine.start() } catch {
            return ChirpEmission(softwareNs: currentMonotonicNs(),
                                 hardwareNs: nil, source: .softwareFallback)
        }

        let softwareStart = currentMonotonicNs()

        // Warmup: let the engine run for a render cycle so
        // `player.lastRenderTime` populates with a valid `AVAudioTime`.
        // Without this, the very first `player.scheduleBuffer(..., at: nil, ...)`
        // traps internally with:
        //   "required condition is false: nodeTime == nil ||
        //    nodeTime.sampleTimeValid || nodeTime.hostTimeValid"
        // because AVAudioEngine's scheduleBuffer touches the player's
        // internal nodeTime (not ours — iOS's), and that nodeTime is
        // invalid immediately after `engine.start()` when the audio
        // session is in a degraded state (which is the norm while
        // AVCaptureSession is actively recording audio on the ego
        // camera).
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Pre-flight: if after the warmup the engine still has no valid
        // timing, bail out BEFORE touching scheduleBuffer — calling it
        // in this state crashes the process with an uncatchable
        // NSException and takes `stopRecording` down with it.
        // Software-only emission is the right graceful fallback: no
        // audible chirp, but the recording stops cleanly and the
        // software-clock anchor in sync_point.json is still correct
        // for post-hoc alignment.
        guard let preflightRenderTime = player.lastRenderTime,
              (preflightRenderTime.isHostTimeValid
               || preflightRenderTime.isSampleTimeValid)
        else {
            engine.stop()
            return ChirpEmission(softwareNs: softwareStart,
                                 hardwareNs: nil, source: .softwareFallback)
        }

        var hardwareStart: UInt64? = nil

        return await withCheckedContinuation { (cont: CheckedContinuation<ChirpEmission, Never>) in
            player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
                // Completion on render thread; we captured times upfront.
                // Stop engine asynchronously so we don't block the audio thread.
                DispatchQueue.global(qos: .utility).async { engine.stop() }
            }

            // Extract host time for sync anchoring when available. The
            // pre-flight above gated on validity; re-fetch lastRenderTime
            // in case the engine's clock advanced between then and now.
            if let lastRenderTime = player.lastRenderTime,
               let nodeTime = player.playerTime(forNodeTime: lastRenderTime),
               nodeTime.isHostTimeValid {
                var tb = mach_timebase_info_data_t()
                mach_timebase_info(&tb)
                let hostTime = nodeTime.hostTime
                hardwareStart = hostTime &* UInt64(tb.numer) / UInt64(tb.denom)
            }

            player.play()

            let source: ChirpSource = (hardwareStart != nil) ? .hardware : .softwareFallback
            cont.resume(returning: ChirpEmission(
                softwareNs: softwareStart,
                hardwareNs: hardwareStart,
                source: source))
        }
        #else
        return ChirpEmission(softwareNs: currentMonotonicNs(),
                             hardwareNs: nil, source: .softwareFallback)
        #endif
    }

    private let sampleRate: Double
}
