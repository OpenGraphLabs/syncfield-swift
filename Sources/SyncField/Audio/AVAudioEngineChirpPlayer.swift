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

        do { try engine.start() } catch {
            return ChirpEmission(softwareNs: currentMonotonicNs(),
                                 hardwareNs: nil, source: .softwareFallback)
        }

        let softwareStart = currentMonotonicNs()
        var hardwareStart: UInt64? = nil

        return await withCheckedContinuation { (cont: CheckedContinuation<ChirpEmission, Never>) in
            player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
                // Completion on render thread; we captured times upfront.
                // Stop engine asynchronously so we don't block the audio thread.
                DispatchQueue.global(qos: .utility).async { engine.stop() }
            }

            // Capture AVAudioTime.hostTime *after* scheduling, before play.
            // lastRenderTime is non-nil once the engine has started.
            if let lastRenderTime = player.lastRenderTime,
               let nodeTime = player.playerTime(forNodeTime: lastRenderTime) {
                // hostTime on iOS is mach_absolute_time ticks
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
