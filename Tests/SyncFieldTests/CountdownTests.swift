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

    func test_countdownTicksAfterStreamsHaveStarted() async throws {
        let (s, _) = makeSession()
        let recorder = CountdownStartOrderRecorder()
        try await s.add(DelayedStartStream(streamId: "a", delayNs: 80_000_000, recorder: recorder))
        try await s.connect()

        let spec = CountdownSpec(ticks: 1, intervalMs: 50, style: .silent)
        _ = try await s.startRecording(countdown: spec) { _ in
            recorder.markTick()
        }

        let startNs = await recorder.streamStartNs
        let tickNs = await recorder.firstTickNs
        XCTAssertNotNil(startNs)
        XCTAssertNotNil(tickNs)
        XCTAssertGreaterThanOrEqual(
            tickNs ?? 0,
            startNs ?? UInt64.max,
            "visible/audible countdown must not begin until streams have acknowledged start")
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

private actor CountdownStartOrderRecorder {
    private(set) var streamStartNs: UInt64?
    private(set) var firstTickNs: UInt64?

    func markStreamStarted() {
        streamStartNs = DispatchTime.now().uptimeNanoseconds
    }

    nonisolated func markTick() {
        Task { await self.markTickInside() }
    }

    private func markTickInside() {
        if firstTickNs == nil {
            firstTickNs = DispatchTime.now().uptimeNanoseconds
        }
    }
}

private final class DelayedStartStream: SyncFieldStream, @unchecked Sendable {
    nonisolated let streamId: String
    nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false,
        producesFile: false)

    private let delayNs: UInt64
    private let recorder: CountdownStartOrderRecorder

    init(streamId: String, delayNs: UInt64, recorder: CountdownStartOrderRecorder) {
        self.streamId = streamId
        self.delayNs = delayNs
        self.recorder = recorder
    }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}

    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {
        try await Task.sleep(nanoseconds: delayNs)
        await recorder.markStreamStarted()
    }

    func stopRecording() async throws -> StreamStopReport {
        StreamStopReport(streamId: streamId, frameCount: 0, kind: "sensor")
    }

    func ingest(
        into dir: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
    }

    func disconnect() async throws {}
}
