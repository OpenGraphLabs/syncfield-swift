// Sources/SyncField/Calibration/CameraCalibrationProber.swift
import Foundation

/// One-time-per-device factory calibration extractor with disk-backed caching.
///
/// Flow:
///   1. `probeIfNeeded()` first checks the on-disk cache at
///      `{cacheDirectory}/camera_calibration_{deviceModel}.json`.
///   2. If present and decodable → return cached value, no probe.
///   3. If missing or corrupted → delegate to `PhotoCalibrationProbeExecutor`,
///      persist the result on success, return it.
///
/// The actor isolates cache file I/O from concurrent callers. Failures from
/// the executor propagate to the caller; no cache file is written on failure,
/// so retries on the next session attempt the probe again.
///
/// `probeStereoIfNeeded()` / `cachedStereo()` mirror the same flow for the
/// stereo (ultra-wide + wide) probe, caching separately at
/// `camera_calibration_stereo_{deviceModel}.json` via the optional
/// `stereoExecutor` dependency. The mono cache and API above are untouched.
public actor CameraCalibrationProber {
    private let cacheDirectory: URL
    private let deviceModel: String
    private let executor: PhotoCalibrationProbeExecutor
    private let stereoExecutor: StereoCalibrationProbeExecutor?

    public init(
        cacheDirectory: URL,
        deviceModel: String,
        executor: PhotoCalibrationProbeExecutor,
        stereoExecutor: StereoCalibrationProbeExecutor? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        self.deviceModel = deviceModel
        self.executor = executor
        self.stereoExecutor = stereoExecutor
    }

    /// Returns the cached calibration if a valid one exists on disk. Returns
    /// nil if the file is missing OR malformed (a corrupt cache reads as nil,
    /// which lets `probeIfNeeded` re-run the executor on the next call).
    public func cached() -> ProbedCameraCalibration? {
        let url = cacheURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProbedCameraCalibration.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    /// Returns the cached calibration if available, otherwise runs the executor
    /// once, writes the result to disk, and returns it. Throws if the executor
    /// itself throws (caller decides retry/fallback policy — no cache file is
    /// written on failure).
    public func probeIfNeeded() async throws -> ProbedCameraCalibration {
        if let hit = cached() { return hit }

        // Cache miss / corrupt — run executor.
        let probed = try await executor.probe(deviceModel: deviceModel)

        // Best-effort cache write. A failed write does not invalidate the
        // returned value — the next session will simply re-probe.
        try? ensureCacheDirectoryExists()
        if let encoded = try? JSONEncoder().encode(probed) {
            try? encoded.write(to: cacheURL(), options: .atomic)
        }

        return probed
    }

    /// Removes the cache file. Idempotent — no error if the file is absent.
    public func clearCache() {
        let url = cacheURL()
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the cached stereo calibration if a valid one exists on disk.
    /// Returns nil if the file is missing OR malformed (a corrupt cache reads
    /// as nil, which lets `probeStereoIfNeeded` re-run the executor on the
    /// next call). Mirrors `cached()` — the mono cache is untouched.
    public func cachedStereo() -> StereoProbedCalibration? {
        let url = stereoCacheURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StereoProbedCalibration.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    /// Returns the cached stereo calibration if available, otherwise runs the
    /// stereo executor once, writes the result to disk, and returns it.
    /// Throws `ProbeError.unsupportedDevice` if no `stereoExecutor` was
    /// configured. Mirrors `probeIfNeeded()` — the mono cache is untouched.
    public func probeStereoIfNeeded() async throws -> StereoProbedCalibration {
        if let hit = cachedStereo() { return hit }

        guard let stereoExecutor else {
            throw ProbeError.unsupportedDevice
        }

        // Cache miss / corrupt — run executor.
        let probed = try await stereoExecutor.probeStereo(deviceModel: deviceModel)

        // Best-effort cache write. A failed write does not invalidate the
        // returned value — the next session will simply re-probe.
        try? ensureCacheDirectoryExists()
        if let encoded = try? JSONEncoder().encode(probed) {
            try? encoded.write(to: stereoCacheURL(), options: .atomic)
        }

        return probed
    }

    /// Removes the stereo cache file. Idempotent — no error if the file is
    /// absent. Leaves the mono cache untouched.
    public func clearStereoCache() {
        let url = stereoCacheURL()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func cacheURL() -> URL {
        cacheDirectory.appendingPathComponent("camera_calibration_\(deviceModel).json")
    }

    private func stereoCacheURL() -> URL {
        cacheDirectory.appendingPathComponent("camera_calibration_stereo_\(deviceModel).json")
    }

    private func ensureCacheDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        }
    }
}
