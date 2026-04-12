# syncfield-swift v0.2 — Plan A.1: Audio capture + Chirp emission

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add audio capture to `iPhoneCameraStream` and integrate `SessionOrchestrator` with a chirp emitter that plays a tone at recording start and stop. Timestamps of the emissions are persisted into `sync_point.json`, matching the Python SDK's contract, so the syncfield server can cross-correlate audio waveforms to pinpoint exact start/stop moments.

**Architecture:** `iPhoneCameraStream` is extended with an audio input (`AVCaptureDeviceInput` for mic) and writes an AAC audio track into the same mp4 as the video track via `AVAssetWriter`. A new `ChirpPlayer` protocol abstracts tone emission; the default implementation uses `AVAudioEngine` with a procedurally-synthesized linear FM sweep. `SessionOrchestrator` gains chirp hooks: start chirp plays after all streams are active (200 ms stabilization delay), stop chirp plays before streams close (with tail margin). Emission timestamps are captured via `AVAudioTime.hostTime` when available (tagged `hardware`) or `mach_absolute_time` (tagged `software_fallback`).

**Tech Stack:** AVFoundation (audio capture + `AVAssetWriter` audio input), AVAudioEngine (chirp synthesis/playback), existing `SessionClock` for timestamp conversion.

**Spec source:** Python `syncfield/src/syncfield/tone.py` + `writer.py:164-220`. Defaults mirrored verbatim.

---

## Phase A1-1: `ChirpSpec`, `ChirpEmission`, `ChirpSource`

### Task 1.1: Value types

**Files:**
- Create: `Sources/SyncField/Audio/ChirpTypes.swift`
- Create: `Tests/SyncFieldTests/ChirpTypesTests.swift`

- [ ] **Step 1: Write tests (expect FAIL)**

```swift
// Tests/SyncFieldTests/ChirpTypesTests.swift
import XCTest
@testable import SyncField

final class ChirpTypesTests: XCTestCase {
    func test_default_start_chirp_matches_python_sdk() {
        let s = ChirpSpec.defaultStart
        XCTAssertEqual(s.fromHz, 400)
        XCTAssertEqual(s.toHz, 2500)
        XCTAssertEqual(s.durationMs, 500)
        XCTAssertEqual(s.amplitude, 0.8, accuracy: 0.001)
        XCTAssertEqual(s.envelopeMs, 15)
    }

    func test_default_stop_chirp_is_reverse_sweep() {
        let s = ChirpSpec.defaultStop
        XCTAssertEqual(s.fromHz, 2500)
        XCTAssertEqual(s.toHz, 400)
    }

    func test_chirp_spec_json_uses_snake_case() throws {
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ChirpSpec.defaultStart)) as! [String: Any]
        XCTAssertEqual(Set(dict.keys),
            ["from_hz", "to_hz", "duration_ms", "amplitude", "envelope_ms"])
    }

    func test_chirp_emission_best_ns_prefers_hardware() {
        let e1 = ChirpEmission(softwareNs: 100, hardwareNs: 200, source: .hardware)
        XCTAssertEqual(e1.bestNs, 200)
        let e2 = ChirpEmission(softwareNs: 100, hardwareNs: nil, source: .softwareFallback)
        XCTAssertEqual(e2.bestNs, 100)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/SyncField/Audio/ChirpTypes.swift
import Foundation

public struct ChirpSpec: Codable, Equatable, Sendable {
    public let fromHz: Double
    public let toHz: Double
    public let durationMs: Double
    public let amplitude: Double
    public let envelopeMs: Double

    public init(fromHz: Double, toHz: Double, durationMs: Double,
                amplitude: Double, envelopeMs: Double) {
        self.fromHz = fromHz; self.toHz = toHz
        self.durationMs = durationMs
        self.amplitude = amplitude
        self.envelopeMs = envelopeMs
    }

    enum CodingKeys: String, CodingKey {
        case fromHz     = "from_hz"
        case toHz       = "to_hz"
        case durationMs = "duration_ms"
        case amplitude
        case envelopeMs = "envelope_ms"
    }

    // Defaults copied verbatim from Python tone.py:54-62
    public static let defaultStart = ChirpSpec(
        fromHz: 400, toHz: 2500, durationMs: 500, amplitude: 0.8, envelopeMs: 15)

    public static let defaultStop = ChirpSpec(
        fromHz: 2500, toHz: 400, durationMs: 500, amplitude: 0.8, envelopeMs: 15)
}

public enum ChirpSource: String, Codable, Sendable {
    case hardware
    case softwareFallback = "software_fallback"
    case silent
}

public struct ChirpEmission: Sendable {
    public let softwareNs: UInt64
    public let hardwareNs: UInt64?
    public let source: ChirpSource

    public init(softwareNs: UInt64, hardwareNs: UInt64?, source: ChirpSource) {
        self.softwareNs = softwareNs
        self.hardwareNs = hardwareNs
        self.source = source
    }

    public var bestNs: UInt64 { hardwareNs ?? softwareNs }
}
```

- [ ] **Step 3: Test PASS, commit**

```bash
git add Sources/SyncField/Audio/ChirpTypes.swift Tests/SyncFieldTests/ChirpTypesTests.swift
git commit -m "feat: add ChirpSpec, ChirpEmission, ChirpSource matching Python defaults"
```

---

## Phase A1-2: `ChirpPlayer` protocol + silent default

### Task 2.1: Protocol + silent implementation

**Files:**
- Create: `Sources/SyncField/Audio/ChirpPlayer.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/SyncField/Audio/ChirpPlayer.swift
import Foundation

/// Abstraction over tone emission. The default iOS implementation is
/// `AVAudioEngineChirpPlayer`; use `SilentChirpPlayer` for tests or
/// when running on a host without audio output.
public protocol ChirpPlayer: Sendable {
    var isSilent: Bool { get }
    func play(_ spec: ChirpSpec) async -> ChirpEmission
}

public struct SilentChirpPlayer: ChirpPlayer {
    public init() {}
    public var isSilent: Bool { true }
    public func play(_ spec: ChirpSpec) async -> ChirpEmission {
        let now = currentMonotonicNs()
        return ChirpEmission(softwareNs: now, hardwareNs: nil, source: .silent)
    }
}

@inline(__always)
func currentMonotonicNs() -> UInt64 {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom)
}
```

- [ ] **Step 2: Verify build, commit**

```bash
swift build
git add Sources/SyncField/Audio/ChirpPlayer.swift
git commit -m "feat: add ChirpPlayer protocol and SilentChirpPlayer default"
```

---

## Phase A1-3: Linear FM sweep synthesis

### Task 3.1: Pure-function sample generator (testable on macOS)

**Files:**
- Create: `Sources/SyncField/Audio/ChirpSynthesis.swift`
- Create: `Tests/SyncFieldTests/ChirpSynthesisTests.swift`

- [ ] **Step 1: Write tests (expect FAIL)**

```swift
// Tests/SyncFieldTests/ChirpSynthesisTests.swift
import XCTest
@testable import SyncField

final class ChirpSynthesisTests: XCTestCase {
    func test_synthesize_produces_expected_sample_count() {
        let spec = ChirpSpec(fromHz: 1000, toHz: 1000, durationMs: 100,
                             amplitude: 1.0, envelopeMs: 0)
        let samples = ChirpSynthesis.render(spec, sampleRate: 44100)
        // 100ms at 44.1 kHz = 4410 samples
        XCTAssertEqual(samples.count, 4410)
    }

    func test_synthesize_respects_amplitude() {
        let spec = ChirpSpec(fromHz: 1000, toHz: 1000, durationMs: 10,
                             amplitude: 0.5, envelopeMs: 0)
        let samples = ChirpSynthesis.render(spec, sampleRate: 44100)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.5 + 1e-6)
        XCTAssertGreaterThan(peak, 0.4)  // should reach near amplitude
    }

    func test_envelope_tapers_ends_to_zero() {
        let spec = ChirpSpec(fromHz: 1000, toHz: 1000, durationMs: 100,
                             amplitude: 1.0, envelopeMs: 15)
        let samples = ChirpSynthesis.render(spec, sampleRate: 44100)
        // First and last sample should be very close to zero due to envelope
        XCTAssertLessThan(abs(samples.first!), 0.05)
        XCTAssertLessThan(abs(samples.last!), 0.05)
    }
}
```

- [ ] **Step 2: Implement linear FM sweep**

```swift
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
        let twoPi = 2.0 * .pi
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
```

- [ ] **Step 3: Tests PASS, commit**

```bash
git add Sources/SyncField/Audio/ChirpSynthesis.swift Tests/SyncFieldTests/ChirpSynthesisTests.swift
git commit -m "feat: ChirpSynthesis.render — linear FM sweep with cosine envelope"
```

---

## Phase A1-4: `AVAudioEngineChirpPlayer`

### Task 4.1: Playback with hardware timestamp capture

**Files:**
- Create: `Sources/SyncField/Audio/AVAudioEngineChirpPlayer.swift`

No new unit test file — device-level playback isn't unit testable on macOS CI. An iOS-gated integration test is optional and not required for this plan.

- [ ] **Step 1: Implement**

```swift
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
```

**Notes for the implementer:**
- The `lastRenderTime`/`playerTime(forNodeTime:)` pair is Apple's documented way to convert an audio-clock tick to the mach host-time tick. If either is nil we fall back gracefully.
- Chirp is "fire and forget" — we return as soon as playback is scheduled; the tail plays out while the session proceeds. For the **stop** chirp, the orchestrator adds 500 ms + 200 ms tail margin delay before closing streams (see Phase A1-6).

- [ ] **Step 2: Verify build, commit**

```bash
swift build
git add Sources/SyncField/Audio/AVAudioEngineChirpPlayer.swift
git commit -m "feat: AVAudioEngineChirpPlayer with hardware timestamp capture"
```

---

## Phase A1-5: Add audio capture to `iPhoneCameraStream`

### Task 5.1: Record mic audio into the mp4

**Files:**
- Modify: `Sources/SyncField/Streams/iPhoneCameraStream.swift`

Audio capture is added to the same `AVCaptureSession` and fed into `AVAssetWriter` as a second track. Pattern:
1. Add `AVCaptureDevice.default(for: .audio)` as a second `AVCaptureDeviceInput`.
2. Add an `AVCaptureAudioDataOutput` with a delegate on the same queue.
3. `AVAssetWriter` gets a second `AVAssetWriterInput` for audio (AAC, 44100 Hz, 1 channel).
4. Route audio sample buffers to the asset writer's audio input when `isRecording`.
5. The class already conforms to `AVCaptureVideoDataOutputSampleBufferDelegate`; extend conformance to `AVCaptureAudioDataOutputSampleBufferDelegate` (same selector — the delegate method fires for both outputs, we discriminate by which output fired).

- [ ] **Step 1: Add audio fields + configure session**

Add these properties to the `#if canImport(AVFoundation)` private section:

```swift
private let audioOutput = AVCaptureAudioDataOutput()
private var assetWriterAudioInput: AVAssetWriterInput?
```

In `configureSession()` after the video input+output are added, add:

```swift
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }
        }
        // If mic is unavailable (permissions, hardware) we fall through without audio.
```

- [ ] **Step 2: Add audio input to AVAssetWriter in `startRecording`**

In `startRecording`, after `writer.add(input)`:

```swift
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 64000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            assetWriterAudioInput = audioInput
        }
```

- [ ] **Step 3: Route audio buffers in the delegate**

In the existing `captureOutput(_:didOutput:from:)`, discriminate by output:

```swift
        if output is AVCaptureAudioDataOutput {
            guard isRecording,
                  let audioInput = assetWriterAudioInput,
                  audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            return
        }
        // ... existing video-output logic unchanged ...
```

- [ ] **Step 4: Clean up in `stopRecording`**

In `stopRecording`, mark the audio input finished before `finishWriting`:

```swift
        assetWriterAudioInput?.markAsFinished()
        assetWriterInput?.markAsFinished()
        // ... existing finishWriting ...
        assetWriterAudioInput = nil
```

- [ ] **Step 5: Update `StreamCapabilities` of the camera stream**

```swift
public nonisolated let capabilities = StreamCapabilities(
    requiresIngest: false, producesFile: true,
    supportsPreciseTimestamps: true,
    providesAudioTrack: true)
```

You'll need to add `providesAudioTrack` to `StreamCapabilities` as well:

```swift
// Sources/SyncField/StreamCapabilities.swift (modification)
public struct StreamCapabilities: Codable, Equatable, Sendable {
    public var requiresIngest: Bool
    public var producesFile: Bool
    public var supportsPreciseTimestamps: Bool
    public var providesAudioTrack: Bool

    public init(requiresIngest: Bool = false,
                producesFile: Bool = true,
                supportsPreciseTimestamps: Bool = true,
                providesAudioTrack: Bool = false) {
        self.requiresIngest = requiresIngest
        self.producesFile = producesFile
        self.supportsPreciseTimestamps = supportsPreciseTimestamps
        self.providesAudioTrack = providesAudioTrack
    }

    enum CodingKeys: String, CodingKey {
        case requiresIngest = "requires_ingest"
        case producesFile   = "produces_file"
        case supportsPreciseTimestamps = "supports_precise_timestamps"
        case providesAudioTrack = "provides_audio_track"
    }
}
```

Update `StreamCapabilitiesTests` to include the new field:

```swift
// Amend test_default_is_native_live_stream:
XCTAssertFalse(c.providesAudioTrack)

// Amend test_json_uses_snake_case — expected key set:
XCTAssertEqual(Set(dict.keys),
    ["requires_ingest", "produces_file",
     "supports_precise_timestamps", "provides_audio_track"])
```

- [ ] **Step 6: Commit**

```bash
git add Sources/SyncField/StreamCapabilities.swift \
        Tests/SyncFieldTests/StreamCapabilitiesTests.swift \
        Sources/SyncField/Streams/iPhoneCameraStream.swift
git commit -m "feat: iPhoneCameraStream records mic audio alongside video"
```

---

## Phase A1-6: Orchestrator chirp integration

### Task 6.1: Emit chirps at start/stop, persist to sync_point.json

**Files:**
- Modify: `Sources/SyncField/SessionOrchestrator.swift`
- Modify: `Sources/SyncField/SyncPoint.swift`

- [ ] **Step 1: Extend `SyncPoint` with chirp fields**

The server reads `chirp_start_ns`, `chirp_stop_ns`, `chirp_start_source`, `chirp_stop_source`, `chirp_spec` from `sync_point.json`. Add them as **optional** fields so they're omitted entirely when chirps are disabled (matches Python writer.py behaviour — absent, not null).

```swift
// Sources/SyncField/SyncPoint.swift — REPLACE existing contents with:
import Foundation

public struct SyncPoint: Codable, Equatable, Sendable {
    public let sdkVersion: String
    public let monotonicNs: UInt64
    public let wallClockNs: UInt64
    public let hostId: String
    public let isoDatetime: String

    // Chirp fields — nil when chirps are disabled
    public var chirpStartNs: UInt64?
    public var chirpStopNs: UInt64?
    public var chirpStartSource: ChirpSource?
    public var chirpStopSource: ChirpSource?
    public var chirpSpec: ChirpSpec?

    public init(sdkVersion: String, monotonicNs: UInt64, wallClockNs: UInt64,
                hostId: String, isoDatetime: String,
                chirpStartNs: UInt64? = nil,
                chirpStopNs: UInt64? = nil,
                chirpStartSource: ChirpSource? = nil,
                chirpStopSource: ChirpSource? = nil,
                chirpSpec: ChirpSpec? = nil) {
        self.sdkVersion  = sdkVersion
        self.monotonicNs = monotonicNs
        self.wallClockNs = wallClockNs
        self.hostId      = hostId
        self.isoDatetime = isoDatetime
        self.chirpStartNs = chirpStartNs
        self.chirpStopNs  = chirpStopNs
        self.chirpStartSource = chirpStartSource
        self.chirpStopSource  = chirpStopSource
        self.chirpSpec = chirpSpec
    }

    enum CodingKeys: String, CodingKey {
        case sdkVersion  = "sdk_version"
        case monotonicNs = "monotonic_ns"
        case wallClockNs = "wall_clock_ns"
        case hostId      = "host_id"
        case isoDatetime = "iso_datetime"
        case chirpStartNs     = "chirp_start_ns"
        case chirpStopNs      = "chirp_stop_ns"
        case chirpStartSource = "chirp_start_source"
        case chirpStopSource  = "chirp_stop_source"
        case chirpSpec        = "chirp_spec"
    }
}
```

The existing `SyncPointTests.test_round_trip_json_preserves_all_fields` still passes (no chirp fields → encoded with `nil` → default JSONEncoder omits nil). `test_json_keys_match_server_contract` will break because a SyncPoint without chirp fields encodes only the 5 base keys — good, the test asserts `Set(dict.keys) == {5 base keys}` which still holds (nils are omitted).

But Swift's default `JSONEncoder` encodes `Optional.none` as `null`, not as absent. Use `JSONEncoder.KeyEncodingStrategy` — actually easier: write a custom `encode(to:)` that skips nil fields:

```swift
public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(sdkVersion,  forKey: .sdkVersion)
    try c.encode(monotonicNs, forKey: .monotonicNs)
    try c.encode(wallClockNs, forKey: .wallClockNs)
    try c.encode(hostId,      forKey: .hostId)
    try c.encode(isoDatetime, forKey: .isoDatetime)
    // Chirp fields: only encode if present
    try c.encodeIfPresent(chirpStartNs,     forKey: .chirpStartNs)
    try c.encodeIfPresent(chirpStopNs,      forKey: .chirpStopNs)
    try c.encodeIfPresent(chirpStartSource, forKey: .chirpStartSource)
    try c.encodeIfPresent(chirpStopSource,  forKey: .chirpStopSource)
    try c.encodeIfPresent(chirpSpec,        forKey: .chirpSpec)
}
```

Add this method inside the `SyncPoint` struct.

Add a test:

```swift
// Add to Tests/SyncFieldTests/SyncPointTests.swift
func test_chirp_fields_are_omitted_when_nil() throws {
    let sp = SyncPoint(sdkVersion: "0.2.0", monotonicNs: 1, wallClockNs: 2,
                       hostId: "h", isoDatetime: "d")
    let dict = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(sp)) as! [String: Any]
    XCTAssertFalse(dict.keys.contains("chirp_start_ns"))
    XCTAssertFalse(dict.keys.contains("chirp_spec"))
}

func test_chirp_fields_are_present_when_set() throws {
    var sp = SyncPoint(sdkVersion: "0.2.0", monotonicNs: 1, wallClockNs: 2,
                       hostId: "h", isoDatetime: "d")
    sp.chirpStartNs = 100
    sp.chirpStartSource = .hardware
    sp.chirpSpec = ChirpSpec.defaultStart
    let dict = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(sp)) as! [String: Any]
    XCTAssertEqual(dict["chirp_start_ns"] as? UInt64, 100)
    XCTAssertEqual(dict["chirp_start_source"] as? String, "hardware")
    XCTAssertNotNil(dict["chirp_spec"])
}
```

- [ ] **Step 2: Wire chirp into `SessionOrchestrator`**

Add properties and init options:

```swift
public actor SessionOrchestrator {
    public init(hostId: String,
                outputDirectory: URL,
                chirpPlayer: ChirpPlayer? = nil,
                startChirp: ChirpSpec? = .defaultStart,
                stopChirp: ChirpSpec? = .defaultStop,
                postStartStabilizationMs: Double = 200,
                preStopTailMarginMs: Double = 200) {
        self.hostId = hostId
        self.baseDir = outputDirectory
        self.chirpPlayer = chirpPlayer ?? SilentChirpPlayer()
        self.startChirpSpec = startChirp
        self.stopChirpSpec = stopChirp
        self.postStartStabilizationMs = postStartStabilizationMs
        self.preStopTailMarginMs = preStopTailMarginMs
    }

    // ... existing state ...
    private let chirpPlayer: ChirpPlayer
    private let startChirpSpec: ChirpSpec?
    private let stopChirpSpec: ChirpSpec?
    private let postStartStabilizationMs: Double
    private let preStopTailMarginMs: Double
    private var startEmission: ChirpEmission?
    private var stopEmission: ChirpEmission?
    private var currentSyncPoint: SyncPoint?
}
```

In `startRecording(...)`, after all streams are running (atomic start has succeeded), emit the start chirp:

```swift
    // ... existing atomic start ...

    state = .recording

    // Chirp: wait for audio pipeline to stabilize, then emit
    if let spec = startChirpSpec {
        if postStartStabilizationMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(postStartStabilizationMs * 1_000_000))
        }
        self.startEmission = await chirpPlayer.play(spec)
    }

    // Update the on-disk sync_point.json with the chirp emission
    if let emission = startEmission {
        var sp = anchor
        sp.chirpStartNs = emission.bestNs
        sp.chirpStartSource = emission.source
        sp.chirpSpec = startChirpSpec
        try writeSyncPoint(sp)
        self.currentSyncPoint = sp
    } else {
        self.currentSyncPoint = anchor
    }

    return anchor
```

In `stopRecording()`, emit the stop chirp *before* closing streams, then wait for the tail:

```swift
public func stopRecording() async throws -> StopReport {
    try require(state: .recording, next: .stopping)

    // Stop chirp: emit first, wait for tail to be captured
    if let spec = stopChirpSpec {
        self.stopEmission = await chirpPlayer.play(spec)
        let waitMs = spec.durationMs + preStopTailMarginMs
        try? await Task.sleep(nanoseconds: UInt64(waitMs * 1_000_000))

        // Update sync_point.json with stop chirp
        if var sp = currentSyncPoint, let em = stopEmission {
            sp.chirpStopNs = em.bestNs
            sp.chirpStopSource = em.source
            try writeSyncPoint(sp)
            self.currentSyncPoint = sp
        }
    }

    // ... existing stream.stopRecording loop ...
}
```

Note: `writeSyncPoint` is called twice now (once in start, once in stop). The file is overwritten atomically each time. Update the private helper signature to accept a `SyncPoint` argument:

```swift
private func writeSyncPoint(_ sp: SyncPoint) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(sp).write(to: episodeDirectory
        .appendingPathComponent("sync_point.json"), options: [.atomic])
}
```

- [ ] **Step 3: Add orchestrator chirp test**

```swift
// Create Tests/SyncFieldTests/SessionOrchestratorChirpTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorChirpTests: XCTestCase {
    final class SpyChirpPlayer: ChirpPlayer, @unchecked Sendable {
        var played: [ChirpSpec] = []
        var isSilent: Bool { false }
        func play(_ spec: ChirpSpec) async -> ChirpEmission {
            played.append(spec)
            return ChirpEmission(softwareNs: 42, hardwareNs: nil, source: .softwareFallback)
        }
    }

    func test_start_and_stop_chirps_are_emitted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = SpyChirpPlayer()
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: spy,
                                    postStartStabilizationMs: 0,
                                    preStopTailMarginMs: 0)
        try await s.add(MockStream(streamId: "a"))

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        XCTAssertEqual(spy.played.count, 2)
        XCTAssertEqual(spy.played[0], .defaultStart)
        XCTAssertEqual(spy.played[1], .defaultStop)
    }

    func test_chirp_timestamps_land_in_sync_point_json() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: SpyChirpPlayer(),
                                    postStartStabilizationMs: 0,
                                    preStopTailMarginMs: 0)
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }

        let episodeDir = await s.episodeDirectory
        let spURL = episodeDir.appendingPathComponent("sync_point.json")
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: spURL)) as! [String: Any]
        XCTAssertEqual(dict["chirp_start_ns"] as? UInt64, 42)
        XCTAssertEqual(dict["chirp_stop_ns"] as? UInt64, 42)
        XCTAssertEqual(dict["chirp_start_source"] as? String, "software_fallback")
        XCTAssertNotNil(dict["chirp_spec"])
    }

    func test_chirps_can_be_disabled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = SpyChirpPlayer()
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir,
                                    chirpPlayer: spy,
                                    startChirp: nil,
                                    stopChirp: nil)
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }

        XCTAssertTrue(spy.played.isEmpty)
    }
}
```

- [ ] **Step 4: Verify, commit**

```bash
swift test  # previous 19 + new chirp tests (~3-5 added across multiple files)
git add Sources/SyncField/SyncPoint.swift \
        Sources/SyncField/SessionOrchestrator.swift \
        Tests/SyncFieldTests/SyncPointTests.swift \
        Tests/SyncFieldTests/SessionOrchestratorChirpTests.swift
git commit -m "feat: SessionOrchestrator emits chirps at start/stop, persists to sync_point.json"
```

---

## Phase A1-7: Default wiring — real chirp on iOS, silent elsewhere

### Task 7.1: Convenience initializer with platform-appropriate default player

**Files:**
- Modify: `Sources/SyncField/SessionOrchestrator.swift`

- [ ] **Step 1: Replace the default chirpPlayer argument behaviour**

Currently `chirpPlayer: ChirpPlayer? = nil` → `SilentChirpPlayer()`. Change to pick the platform-appropriate default:

```swift
public init(hostId: String,
            outputDirectory: URL,
            chirpPlayer: ChirpPlayer? = nil,
            // ...
) {
    // ...
    self.chirpPlayer = chirpPlayer ?? Self.defaultChirpPlayer()
    // ...
}

private static func defaultChirpPlayer() -> ChirpPlayer {
    #if canImport(AVFoundation) && os(iOS)
    return AVAudioEngineChirpPlayer()
    #else
    return SilentChirpPlayer()
    #endif
}
```

On iOS: real audio engine by default. Everywhere else (macOS unit tests, non-iOS): silent. Customers can always inject their own `ChirpPlayer` (e.g. `SilentChirpPlayer()` for unit tests, or a custom implementation).

- [ ] **Step 2: Commit**

```bash
git add Sources/SyncField/SessionOrchestrator.swift
git commit -m "feat: SessionOrchestrator defaults to AVAudioEngineChirpPlayer on iOS"
```

---

## Phase A1-8: Green-light checkpoint

### Task 8.1: Full test run and tag

- [ ] **Step 1: macOS test suite**

```bash
swift test
```
Expected: all tests pass. Chirp-related tests should run with the silent default player on macOS.

- [ ] **Step 2: iOS Simulator build**

```bash
xcodebuild -scheme SyncField -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -15
xcodebuild -scheme SyncFieldUIKit -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -15
```

- [ ] **Step 3: Tag**

```bash
git tag v0.2.1-plan-a1
```

---

## Self-Review

**Spec coverage against the Python contract:**
- Start/stop chirp defaults (400→2500 / 2500→400 Hz, 500 ms, 0.8 amp, 15 ms envelope): Phase A1-1 ✓
- `post_start_stabilization_ms` (200 ms) and `pre_stop_tail_margin_ms` (200 ms): Phase A1-6 ✓
- `chirp_{start,stop}_{ns,source}` + `chirp_spec` in `sync_point.json`, omitted when disabled: Phase A1-6 ✓
- `ChirpSource` enum (hardware / software_fallback / silent): Phase A1-1 ✓
- `best_ns` helper (hardware preferred, software fallback): Phase A1-1 ✓
- Audio capture on the same host so the server can cross-correlate: Phase A1-5 ✓
- Linear FM sweep with cosine envelope matching Python tone.py:71: Phase A1-3 ✓

**Placeholder scan:** No "TBD"/"TODO". Every code block is complete.

**Type consistency:** `ChirpSpec`, `ChirpEmission`, `ChirpSource` used consistently. `SyncPoint` additions match `CodingKeys`. Orchestrator initializer params match what the chirp test spy verifies.

**Scope check:** Focused on audio + chirp only. Does not touch Tactile or Insta360 (Plans B, C). Does not extend to multi-host (excluded by Plan A scope).

---

## Execution handoff

Plan is complete. Execute with superpowers:subagent-driven-development (recommended — fresh subagent per phase with review between phases) or superpowers:executing-plans (inline batch execution in the current session).
