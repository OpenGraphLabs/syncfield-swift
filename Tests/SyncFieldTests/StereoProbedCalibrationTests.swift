// Tests/SyncFieldTests/StereoProbedCalibrationTests.swift
//
// Model + cache tests for StereoProbedCalibration and the stereo cache
// methods on CameraCalibrationProber. Run on every platform — no AVFoundation
// involved, the stereo probe executor is stubbed via StereoCalibrationProbeExecutor.

import XCTest
@testable import SyncField

private actor StubStereoProbeExecutor: StereoCalibrationProbeExecutor {
    private let result: Result<StereoProbedCalibration, Error>
    private(set) var callCount: Int = 0

    init(result: Result<StereoProbedCalibration, Error>) {
        self.result = result
    }

    func probeStereo(deviceModel: String) async throws -> StereoProbedCalibration {
        callCount += 1
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func observedCallCount() -> Int { callCount }
}

final class StereoProbedCalibrationTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stereo-prober-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func makeMono(fx: Double = 1500, model: String = "iPhone17,1") -> ProbedCameraCalibration {
        ProbedCameraCalibration(
            fx: fx, fy: fx, cx: 2016, cy: 1512,
            referenceWidth: 4032, referenceHeight: 3024,
            lookupTableRadial: (0..<8).map { Float($0) / 8.0 },
            distortionCenterX: 2016, distortionCenterY: 1512,
            deviceModel: model
        )
    }

    private func makeFixture(
        model: String = "iPhone17,1",
        extrinsics: StereoExtrinsics? = StereoExtrinsics(
            rotationRowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            translationMillimeters: [19.2, 0, 0]
        ),
        deviceExtrinsics: StereoExtrinsics? = nil
    ) -> StereoProbedCalibration {
        StereoProbedCalibration(
            ultrawide: makeMono(fx: 1500, model: model),
            wide: makeMono(fx: 2800, model: model),
            extrinsicsUWToWide: extrinsics,
            deviceExtrinsicsUWToWide: deviceExtrinsics,
            probedAtISO8601: "2026-07-16T00:00:00Z"
        )
    }

    // MARK: - Model

    func test_codable_round_trip() throws {
        let fixture = makeFixture()
        let encoded = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(StereoProbedCalibration.self, from: encoded)
        XCTAssertEqual(decoded, fixture)
    }

    func test_baselineMillimeters_from_probe_extrinsics() throws {
        let fixture = makeFixture(
            extrinsics: StereoExtrinsics(
                rotationRowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                translationMillimeters: [19.2, 0, 0]
            )
        )
        let baseline = try XCTUnwrap(fixture.baselineMillimeters)
        XCTAssertEqual(baseline, 19.2, accuracy: 0.0001)
    }

    func test_baselineMillimeters_falls_back_to_device_extrinsics_when_probe_nil() throws {
        let fixture = makeFixture(
            extrinsics: nil,
            deviceExtrinsics: StereoExtrinsics(
                rotationRowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                translationMillimeters: [0, 19.2, 0]
            )
        )
        let baseline = try XCTUnwrap(fixture.baselineMillimeters)
        XCTAssertEqual(baseline, 19.2, accuracy: 0.0001)
    }

    func test_baselineMillimeters_nil_when_both_extrinsics_absent() {
        let fixture = makeFixture(extrinsics: nil, deviceExtrinsics: nil)
        XCTAssertNil(fixture.baselineMillimeters)
    }

    func test_baselineMillimeters_prefers_probe_extrinsics_over_device() throws {
        let fixture = makeFixture(
            extrinsics: StereoExtrinsics(
                rotationRowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                translationMillimeters: [3, 4, 0] // norm 5
            ),
            deviceExtrinsics: StereoExtrinsics(
                rotationRowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                translationMillimeters: [100, 0, 0]
            )
        )
        let baseline = try XCTUnwrap(fixture.baselineMillimeters)
        XCTAssertEqual(baseline, 5, accuracy: 0.0001)
    }

    // MARK: - Prober stereo cache

    func test_cachedStereo_returns_nil_when_no_file_exists() async {
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: StubProbeExecutorForStereoTests()
        )
        let cached = await prober.cachedStereo()
        XCTAssertNil(cached)
    }

    func test_probeStereoIfNeeded_runs_executor_and_writes_cache_on_first_call() async throws {
        let fixture = makeFixture()
        let stereoExecutor = StubStereoProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: StubProbeExecutorForStereoTests(),
            stereoExecutor: stereoExecutor
        )

        let result = try await prober.probeStereoIfNeeded()

        XCTAssertEqual(result, fixture)
        let calls = await stereoExecutor.observedCallCount()
        XCTAssertEqual(calls, 1)

        let cacheURL = workDir.appendingPathComponent("camera_calibration_stereo_iPhone17,1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_probeStereoIfNeeded_returns_cached_on_second_call_without_calling_executor() async throws {
        let fixture = makeFixture()
        let stereoExecutor = StubStereoProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: StubProbeExecutorForStereoTests(),
            stereoExecutor: stereoExecutor
        )

        _ = try await prober.probeStereoIfNeeded()
        let second = try await prober.probeStereoIfNeeded()

        XCTAssertEqual(second, fixture)
        let calls = await stereoExecutor.observedCallCount()
        XCTAssertEqual(calls, 1, "second call must hit disk cache, not executor")
    }

    func test_corrupted_stereo_cache_invalidates_and_re_probes() async throws {
        let cacheURL = workDir.appendingPathComponent("camera_calibration_stereo_iPhone17,1.json")
        try "not valid json {{{".write(to: cacheURL, atomically: true, encoding: .utf8)

        let fixture = makeFixture()
        let stereoExecutor = StubStereoProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: StubProbeExecutorForStereoTests(),
            stereoExecutor: stereoExecutor
        )

        let firstRead = await prober.cachedStereo()
        XCTAssertNil(firstRead, "corrupted stereo cache must read as nil")

        let result = try await prober.probeStereoIfNeeded()
        XCTAssertEqual(result, fixture)
        let calls = await stereoExecutor.observedCallCount()
        XCTAssertEqual(calls, 1, "must run executor when stereo cache is corrupt")
    }

    func test_probeStereoIfNeeded_throws_when_no_stereo_executor_configured() async {
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: StubProbeExecutorForStereoTests()
        )

        do {
            _ = try await prober.probeStereoIfNeeded()
            XCTFail("expected ProbeError.unsupportedDevice")
        } catch let error as ProbeError {
            XCTAssertEqual(error, .unsupportedDevice)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_mono_and_stereo_caches_do_not_collide() async throws {
        let monoFixture = makeMono()
        let monoExecutor = StubProbeExecutorForStereoTests(result: .success(monoFixture))
        let stereoFixture = makeFixture()
        let stereoExecutor = StubStereoProbeExecutor(result: .success(stereoFixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: monoExecutor,
            stereoExecutor: stereoExecutor
        )

        _ = try await prober.probeIfNeeded()
        _ = try await prober.probeStereoIfNeeded()

        let monoCacheURL = workDir.appendingPathComponent("camera_calibration_iPhone17,1.json")
        let stereoCacheURL = workDir.appendingPathComponent("camera_calibration_stereo_iPhone17,1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: monoCacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stereoCacheURL.path))

        let cachedMono = await prober.cached()
        let cachedStereo = await prober.cachedStereo()
        XCTAssertEqual(cachedMono, monoFixture)
        XCTAssertEqual(cachedStereo, stereoFixture)
    }

    func test_clearStereoCache_removes_disk_file_and_leaves_mono_cache_untouched() async throws {
        let monoFixture = makeMono()
        let monoExecutor = StubProbeExecutorForStereoTests(result: .success(monoFixture))
        let stereoFixture = makeFixture()
        let stereoExecutor = StubStereoProbeExecutor(result: .success(stereoFixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: monoExecutor,
            stereoExecutor: stereoExecutor
        )
        _ = try await prober.probeIfNeeded()
        _ = try await prober.probeStereoIfNeeded()

        await prober.clearStereoCache()

        let monoCacheURL = workDir.appendingPathComponent("camera_calibration_iPhone17,1.json")
        let stereoCacheURL = workDir.appendingPathComponent("camera_calibration_stereo_iPhone17,1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: monoCacheURL.path), "mono cache must survive clearStereoCache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stereoCacheURL.path))
        let cachedStereoAfterClear = await prober.cachedStereo()
        XCTAssertNil(cachedStereoAfterClear)
    }
}

/// Local mono stub so this file doesn't depend on the private stub declared
/// in CameraCalibrationProberTests.swift.
private actor StubProbeExecutorForStereoTests: PhotoCalibrationProbeExecutor {
    private let result: Result<ProbedCameraCalibration, Error>

    init(result: Result<ProbedCameraCalibration, Error> = .failure(ProbeError.unsupportedDevice)) {
        self.result = result
    }

    func probe(deviceModel: String) async throws -> ProbedCameraCalibration {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
