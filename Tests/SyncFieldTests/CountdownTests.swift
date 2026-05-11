// Tests/SyncFieldTests/CountdownTests.swift
import XCTest
@testable import SyncField

final class CountdownTests: XCTestCase {

    private func makeSession() -> (SessionOrchestrator, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-cd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // SilentChirpPlayer for tests so chirp emission doesn't try to
        // touch AVAudioEngine on macOS test hosts.
        return (SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            chirpPlayer: SilentChirpPlayer(),
            audioSessionPolicy: .manualByHost), dir)
    }

    // MARK: - CountdownSpec sanity

    func test_standardCountdown_isThreeTicksOneSecondApartAudible() {
        XCTAssertEqual(CountdownSpec.standard.ticks, 3)
        XCTAssertEqual(CountdownSpec.standard.intervalMs, 1000)
        XCTAssertEqual(CountdownSpec.standard.style, .audible)
    }

    func test_silentCountdown_isThreeTicksOneSecondApartSilent() {
        XCTAssertEqual(CountdownSpec.silent.ticks, 3)
        XCTAssertEqual(CountdownSpec.silent.style, .silent)
    }

    func test_initClampsNegativeTicks() {
        let cd = CountdownSpec(ticks: -1, intervalMs: 1000, style: .silent)
        XCTAssertEqual(cd.ticks, 0)
    }

    func test_initClampsSubMinimumInterval() {
        let cd = CountdownSpec(ticks: 3, intervalMs: 10, style: .silent)
        XCTAssertGreaterThanOrEqual(cd.intervalMs, 50)
    }

    // MARK: - End-to-end: onTick fires the expected sequence

    func test_silentCountdown_firesOnTickCountingDown() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()

        let ticks = TickCollector()
        // Use 50 ms intervals so the test stays fast.
        let spec = CountdownSpec(ticks: 3, intervalMs: 50, style: .silent)
        _ = try await s.startRecording(countdown: spec) { remaining in
            ticks.append(remaining)
        }

        let observed = await ticks.snapshot()
        XCTAssertEqual(observed, [3, 2, 1],
                       "onTick must fire once per tick, counting down to 1")
    }

    func test_noCountdown_doesNotInvokeOnTick() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()

        let ticks = TickCollector()
        _ = try await s.startRecording { remaining in
            ticks.append(remaining)
        }

        let observed = await ticks.snapshot()
        XCTAssertEqual(observed, [], "no countdown arg = no ticks")
    }

    func test_zeroTickCountdown_doesNotInvokeOnTick() async throws {
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()

        let ticks = TickCollector()
        let spec = CountdownSpec(ticks: 0, intervalMs: 50, style: .silent)
        _ = try await s.startRecording(countdown: spec) { remaining in
            ticks.append(remaining)
        }

        let observed = await ticks.snapshot()
        XCTAssertEqual(observed, [])
    }

    func test_countdownTakesAtLeastTicksTimesInterval() async throws {
        // The countdown must actually block startRecording until the ticks
        // have run — otherwise the chirp can land before "1" and the UX
        // breaks. We measure wall time and require >= ticks × interval.
        let (s, _) = makeSession()
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()

        let intervalMs = 60.0
        let spec = CountdownSpec(ticks: 3, intervalMs: intervalMs, style: .silent)

        let t0 = Date()
        _ = try await s.startRecording(countdown: spec)
        let elapsedMs = Date().timeIntervalSince(t0) * 1000

        // 3 ticks × 60 ms = 180 ms expected; allow generous lower bound.
        XCTAssertGreaterThanOrEqual(elapsedMs, 3 * intervalMs * 0.9,
                                     "countdown must hold start by at least ticks × interval")
    }

    // MARK: - Pure tone synthesis

    func test_toneSynthesis_producesNonZeroSamples() {
        let samples = ToneSynthesis.render(
            frequencyHz: 880,
            durationSec: 0.11,
            amplitude: 0.9,
            envelopeMs: 8,
            sampleRate: 44100)
        XCTAssertEqual(samples.count, Int(0.11 * 44100))
        // Middle of the tone (past attack envelope) should be near full
        // amplitude — confirms the waveform is actually being generated.
        let mid = samples[samples.count / 2]
        XCTAssertGreaterThan(abs(mid), 0.3)
    }

    func test_toneSynthesis_envelopeRampsInAndOut() {
        let samples = ToneSynthesis.render(
            frequencyHz: 880,
            durationSec: 0.11,
            amplitude: 0.9,
            envelopeMs: 8,
            sampleRate: 44100)
        // First sample of the attack must be ~0 (envelope starts at 0).
        XCTAssertLessThan(abs(samples[0]), 0.05)
        // Last sample of the release must be ~0.
        XCTAssertLessThan(abs(samples[samples.count - 1]), 0.05)
    }
}

// Actor-based collector so onTick (which the SDK marks @Sendable) can
// safely append from whatever queue the countdown runs on.
actor TickCollector {
    private var values: [Int] = []
    nonisolated func append(_ v: Int) {
        Task { await self.appendInside(v) }
    }
    private func appendInside(_ v: Int) { values.append(v) }
    func snapshot() -> [Int] { values }
}
