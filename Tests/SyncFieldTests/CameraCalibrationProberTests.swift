// Tests/SyncFieldTests/CameraCalibrationProberTests.swift
//
// Cache-and-injection tests for CameraCalibrationProber. Run on every platform
// — AVFoundation photo capture is gated behind a separate iOS-only executor
// so the prober's caching, error-propagation, and disk semantics are testable
// in isolation.

import XCTest
@testable import SyncField

private actor StubProbeExecutor: PhotoCalibrationProbeExecutor {
    private let result: Result<ProbedCameraCalibration, Error>
    private(set) var callCount: Int = 0

    init(result: Result<ProbedCameraCalibration, Error>) {
        self.result = result
    }

    func probe(deviceModel: String) async throws -> ProbedCameraCalibration {
        callCount += 1
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func observedCallCount() -> Int { callCount }
}

final class CameraCalibrationProberTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prober-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func makeFixture(model: String = "iPhone17,1") -> ProbedCameraCalibration {
        ProbedCameraCalibration(
            fx: 1500, fy: 1500, cx: 2016, cy: 1512,
            referenceWidth: 4032, referenceHeight: 3024,
            lookupTableRadial: (0..<1024).map { Float($0) / 1024.0 },
            distortionCenterX: 2016, distortionCenterY: 1512,
            deviceModel: model
        )
    }

    func test_cached_returns_nil_when_no_file_exists() async {
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1",
            executor: StubProbeExecutor(result: .success(makeFixture()))
        )
        let cached = await prober.cached()
        XCTAssertNil(cached)
    }

    func test_probeIfNeeded_runs_executor_and_writes_cache_on_first_call() async throws {
        let fixture = makeFixture()
        let executor = StubProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1", executor: executor
        )

        let result = try await prober.probeIfNeeded()

        XCTAssertEqual(result, fixture)
        let calls = await executor.observedCallCount()
        XCTAssertEqual(calls, 1)

        // Cache file must exist on disk.
        let cacheURL = workDir.appendingPathComponent("camera_calibration_iPhone17,1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_probeIfNeeded_returns_cached_on_second_call_without_calling_executor() async throws {
        let fixture = makeFixture()
        let executor = StubProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1", executor: executor
        )

        _ = try await prober.probeIfNeeded()
        let second = try await prober.probeIfNeeded()

        XCTAssertEqual(second, fixture)
        let calls = await executor.observedCallCount()
        XCTAssertEqual(calls, 1, "second call must hit disk cache, not executor")
    }

    func test_corrupted_cache_invalidates_and_re_probes() async throws {
        // Write garbage to where cached() expects a calibration JSON.
        let cacheURL = workDir.appendingPathComponent("camera_calibration_iPhone17,1.json")
        try "not valid json {{{".write(to: cacheURL, atomically: true, encoding: .utf8)

        let fixture = makeFixture()
        let executor = StubProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1", executor: executor
        )

        let firstRead = await prober.cached()
        XCTAssertNil(firstRead, "corrupted cache must read as nil")

        let result = try await prober.probeIfNeeded()
        XCTAssertEqual(result, fixture)
        let calls = await executor.observedCallCount()
        XCTAssertEqual(calls, 1, "must run executor when cache is corrupt")
    }

    func test_clearCache_removes_disk_file() async throws {
        let fixture = makeFixture()
        let executor = StubProbeExecutor(result: .success(fixture))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1", executor: executor
        )
        _ = try await prober.probeIfNeeded()

        await prober.clearCache()

        let cacheURL = workDir.appendingPathComponent("camera_calibration_iPhone17,1.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        let cachedAfterClear = await prober.cached()
        XCTAssertNil(cachedAfterClear)
    }

    func test_probeIfNeeded_propagates_executor_error() async {
        let executor = StubProbeExecutor(result: .failure(ProbeError.unsupportedDevice))
        let prober = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1", executor: executor
        )

        do {
            _ = try await prober.probeIfNeeded()
            XCTFail("expected ProbeError.unsupportedDevice")
        } catch let error as ProbeError {
            XCTAssertEqual(error, .unsupportedDevice)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        // Failed probe must NOT write a cache file (would poison future calls).
        let cacheURL = workDir.appendingPathComponent("camera_calibration_iPhone17,1.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_separate_device_models_have_separate_cache_files() async throws {
        let executor1 = StubProbeExecutor(result: .success(makeFixture(model: "iPhone17,1")))
        let prober1 = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone17,1", executor: executor1
        )
        _ = try await prober1.probeIfNeeded()

        let executor2 = StubProbeExecutor(result: .success(makeFixture(model: "iPhone15,3")))
        let prober2 = CameraCalibrationProber(
            cacheDirectory: workDir, deviceModel: "iPhone15,3", executor: executor2
        )
        _ = try await prober2.probeIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("camera_calibration_iPhone17,1.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("camera_calibration_iPhone15,3.json").path))
        let calls1 = await executor1.observedCallCount()
        let calls2 = await executor2.observedCallCount()
        XCTAssertEqual(calls1, 1)
        XCTAssertEqual(calls2, 1)
    }
}
