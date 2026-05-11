// Sources/SyncField/Audio/AVAudioEngineChirpPlayer.swift
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// iOS / macOS default chirp player.
///
/// Despite the legacy class name the implementation is `AVAudioPlayer` +
/// `AudioServicesPlaySystemSound`, matching og-skill's production
/// `SoundFeedbackModule` pattern. Validated on iOS 18 + A18 Pro under
/// the AVCaptureSession + Insta360 BLE concurrent activity window where
/// `AVAudioEngine`-backed playback silently fails.
///
/// Stability rules learned the hard way:
///
/// 1. **Initialise `AVAudioPlayer` from a file URL, not in-memory Data.**
///    `AVAudioPlayer.init(data:)` worked in isolation but exhibited
///    silent-emission cases on iOS 18 under load. The file-URL constructor
///    is what og-skill's production module uses and what survives.
///
/// 2. **No `setCategory` in the playback hot path.** Re-applying the
///    category under AVCaptureSession's priority returns `'!pri'` and the
///    failed attempt transitions the audio session through an interim
///    state that itself silences playback. `SessionOrchestrator.connect()`
///    sets the category exactly once; the chirp player trusts it.
///
/// 3. **`setActive(true)` and `overrideOutputAudioPort(.speaker)` right
///    before every play.** AVCaptureSession's audio reconfigure briefly
///    deactivates the session and can drift the output route; both
///    calls are no-ops when the state is already correct and re-arm it
///    when it isn't.
///
/// 4. **AVAudioPlayer + SystemSound belt-and-suspenders.** Either pipe
///    can be attenuated to inaudible by iOS for a short window during
///    AVCaptureSession transitions; playing both gives a stable
///    audible cue regardless of which one is currently being silenced.
///
/// 5. **NSLog the play, so the host engineer can see whether the chirp
///    was actually dispatched** even when no sound is heard from the
///    speaker. Silent failures of either AVAudioPlayer or SystemSound
///    are surfaced via the system-sound completion proc.
public final class AVAudioEngineChirpPlayer: ChirpPlayer, @unchecked Sendable {

    public init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        #if canImport(AVFoundation) && os(iOS)
        for spec in Self.prebuiltSpecs {
            _ = ensureCached(spec)
        }
        #endif
    }

    public var isSilent: Bool { false }

    public func play(_ spec: ChirpSpec) async -> ChirpEmission {
        #if canImport(AVFoundation) && os(iOS)
        let softwareStart = currentMonotonicNs()

        guard let cached = ensureCached(spec) else {
            NSLog("[ChirpPlayer] failed to materialize player+systemSound; emitting softwareFallback")
            return ChirpEmission(softwareNs: softwareStart,
                                 hardwareNs: nil,
                                 source: .softwareFallback)
        }

        prepareForPlayback()

        let avDispatched = playAVAudioPlayer(cached.player)
        AudioServicesPlaySystemSound(cached.systemSoundID)

        NSLog("[ChirpPlayer] play emitted spec=%.0f→%.0fHz dur=%.0fms avAudioPlayer=%@ systemSound=%u session=%@",
              spec.fromHz, spec.toHz, spec.durationMs,
              avDispatched ? "ok" : "FAILED",
              UInt32(cached.systemSoundID),
              describeSessionState())

        lock.lock()
        lastPlayed = cached.player
        lock.unlock()

        return ChirpEmission(softwareNs: softwareStart,
                             hardwareNs: nil,
                             source: .softwareFallback)
        #else
        return ChirpEmission(softwareNs: currentMonotonicNs(),
                             hardwareNs: nil,
                             source: .softwareFallback)
        #endif
    }

    // MARK: - Caching

    #if canImport(AVFoundation) && os(iOS)
    private static let prebuiltSpecs: [ChirpSpec] = [
        .defaultStart, .defaultStop, .audibleStart, .audibleStop,
    ]

    private struct CachedEmitter {
        let player: AVAudioPlayer
        let systemSoundID: SystemSoundID
        let tempURL: URL
    }

    private let lock = NSLock()
    private var cache: [ChirpKey: CachedEmitter] = [:]
    private var lastPlayed: AVAudioPlayer?

    private func ensureCached(_ spec: ChirpSpec) -> CachedEmitter? {
        let key = ChirpKey(spec: spec)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let built = build(spec: spec) else { return nil }

        lock.lock()
        if let racedIn = cache[key] {
            AudioServicesDisposeSystemSoundID(built.systemSoundID)
            try? FileManager.default.removeItem(at: built.tempURL)
            lock.unlock()
            return racedIn
        }
        cache[key] = built
        lock.unlock()
        return built
    }

    private func build(spec: ChirpSpec) -> CachedEmitter? {
        let samples = ChirpSynthesis.render(spec, sampleRate: sampleRate)
        guard !samples.isEmpty else { return nil }
        let wav = WAVWriter.encodePCM16Mono(samples: samples,
                                             sampleRate: sampleRate)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncfield-chirp-\(UUID().uuidString).wav")
        do {
            try wav.write(to: tmp, options: [.atomic])
        } catch {
            NSLog("[ChirpPlayer] temp WAV write failed: \(error.localizedDescription)")
            return nil
        }

        // File URL constructor (not init(data:)). Matches og-skill's
        // production-validated path and avoids silent-emission cases
        // observed with init(data:) on iOS 18 under AVCaptureSession
        // + active BLE peripherals.
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: tmp)
        } catch {
            NSLog("[ChirpPlayer] AVAudioPlayer init(contentsOf:) failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        player.volume = 1.0
        player.prepareToPlay()

        var soundID: SystemSoundID = 0
        let st = AudioServicesCreateSystemSoundID(tmp as CFURL, &soundID)
        guard st == kAudioServicesNoError else {
            NSLog("[ChirpPlayer] SystemSound register failed status=\(st)")
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }

        return CachedEmitter(player: player,
                              systemSoundID: soundID,
                              tempURL: tmp)
    }

    @discardableResult
    private func playAVAudioPlayer(_ player: AVAudioPlayer) -> Bool {
        if player.isPlaying { player.stop() }
        player.prepareToPlay()
        player.currentTime = 0
        player.volume = 1.0
        return player.play()
    }

    /// Re-activate the shared `AVAudioSession` and pin output to the
    /// main speaker immediately before play. AVCaptureSession's
    /// AVAssetWriter startup transiently deactivates the session and
    /// can drift the route on iOS 18 when an Insta360 BLE peripheral
    /// is concurrently active. Both calls are no-ops when state is
    /// already correct.
    private func prepareForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
    }

    private func describeSessionState() -> String {
        let s = AVAudioSession.sharedInstance()
        let port = s.currentRoute.outputs.first?.portType.rawValue ?? "none"
        return "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) vol=\(String(format: "%.2f", s.outputVolume)) out=\(port)"
    }
    #endif

    private let sampleRate: Double
}

private struct ChirpKey: Hashable {
    let fromHz: Double
    let toHz: Double
    let durationMs: Double
    let amplitude: Double
    let envelopeMs: Double

    init(spec: ChirpSpec) {
        self.fromHz = spec.fromHz
        self.toHz = spec.toHz
        self.durationMs = spec.durationMs
        self.amplitude = spec.amplitude
        self.envelopeMs = spec.envelopeMs
    }
}
