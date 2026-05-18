// Tests/SyncFieldTests/iPhoneCameraStreamTests.swift
#if os(iOS)
import XCTest
import AVFoundation
@testable import SyncField

/// Helper: thread-safe counter for the frame-processor regression tests.
/// Cannot live as a stored property on `XCTestCase` because the closures
/// capture across test-method boundaries — keep it as a tiny class so the
/// test scope owns the lifecycle.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class iPhoneCameraStreamTests: XCTestCase {
    func test_produces_mp4_and_matching_timestamp_line_count() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego")
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let episodeDir = await s.episodeDirectory
        let mp4 = episodeDir.appendingPathComponent("cam_ego.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))

        let stamps = episodeDir.appendingPathComponent("cam_ego.timestamps.jsonl")
        let lines = try String(contentsOf: stamps).split(separator: "\n")
        let camReport = stop.streamReports.first { $0.streamId == "cam_ego" }!
        XCTAssertEqual(lines.count, camReport.frameCount)
    }

    /// Ensures the 720p preset actually lands a 1280×720 track in the output.
    /// Also serves as a smoke test that the new `videoSettings` init plumbs
    /// through to the AVAssetWriter output settings.
    func test_hd720_preset_produces_1280x720_track() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720)
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let episodeDir = await s.episodeDirectory
        let mp4 = episodeDir.appendingPathComponent("cam_ego.mp4")
        let asset = AVURLAsset(url: mp4)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first)
        let size = try await videoTrack.load(.naturalSize)
        // 720p landed as requested (sensor buffers arrive as 1280×720 so the
        // encoder emits the track at that native size).
        XCTAssertEqual(size.width,  1280, accuracy: 0)
        XCTAssertEqual(size.height, 720,  accuracy: 0)
    }

    // MARK: - Frame processor off-queue dispatch (regression for FPS-drop bug)
    //
    // Production captures through 2026-05-18 showed iPhone egocentric mp4
    // averaging 8–20 fps when a host-installed frame processor (MediaPipe
    // hand landmarker, CPU) ran inline on the capture serial queue. Because
    // `videoOutput.alwaysDiscardsLateVideoFrames = true`, every processor
    // call that exceeded ~33 ms caused AVFoundation to silently drop the
    // next incoming sample. The fix (0.10.0) moves the processor onto a
    // dedicated serial queue via `FrameProcessorGate` and drops on the
    // producer side when prior work is still running. These tests run on
    // device only — the existing tests in this file already require a real
    // back camera, so we follow the same convention.

    /// A frame processor that sleeps 60 ms (~2× the inter-frame budget at
    /// 30 fps) must not reduce the *delivered* frame count. Before the
    /// fix, this would degrade the ego mp4 to ~15–20 fps. After the fix,
    /// the slow processor work runs on its own queue and AVCapture keeps
    /// delivering at the native 30 fps; drop-on-busy means the host
    /// callback simply fires less often, but every captured frame is
    /// still encoded.
    func test_slow_frame_processor_does_not_block_capture_queue() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720)
        cam.setFrameProcessor(throttleHz: 0) { _, _ in
            // 60 ms keeps the gate continuously busy and exceeds the 30 fps
            // inter-frame budget — pre-fix this would synchronously block
            // the capture queue.
            Thread.sleep(forTimeInterval: 0.060)
        }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let camReport = stop.streamReports.first { $0.streamId == "cam_ego" }!
        // 3 s × 30 fps ≈ 90 frames. Allow generous headroom for warm-up,
        // tear-down, and per-device thermal variance. Anything < 60 means
        // capture-queue blocking has regressed.
        XCTAssertGreaterThanOrEqual(
            camReport.frameCount, 60,
            "frame processor blocked capture queue — got \(camReport.frameCount) frames in 3 s")
    }

    /// Drop-on-busy: with a 100 ms processor and a 30 fps source the gate
    /// should accept at most ~10 calls / s, regardless of how many frames
    /// AVCapture delivers. Verifies the producer-side drop policy.
    func test_drop_on_busy_caps_processor_invocations() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720)
        let processorCalls = AtomicCounter()
        cam.setFrameProcessor(throttleHz: 0) { _, _ in
            Thread.sleep(forTimeInterval: 0.100)
            processorCalls.increment()
        }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let calls = processorCalls.value
        let frames = stop.streamReports.first { $0.streamId == "cam_ego" }!.frameCount
        // With 100 ms work in a 2 s window the gate can accept at most
        // ~20 units. Generous upper bound = 30 accommodates the warm-up
        // window where the processor sees a clean gate immediately.
        XCTAssertLessThanOrEqual(
            calls, 30,
            "drop-on-busy didn't cap invocations — got \(calls) calls vs \(frames) captured frames")
        // And it must have actually fired at least a handful of times,
        // otherwise we'd be testing a no-op.
        XCTAssertGreaterThanOrEqual(calls, 5)
        // Captured frames must still hit the ~30 fps ceiling.
        XCTAssertGreaterThanOrEqual(
            frames, 40,
            "captured frame count fell off (\(frames) frames in 2 s)")
    }

    /// A fast processor (≪ inter-frame budget) must still be called
    /// roughly once per delivered frame — i.e., the off-queue dispatch
    /// didn't introduce false drops in the happy path. Without
    /// throttling, calls ≈ frame count.
    func test_fast_frame_processor_called_for_every_delivered_frame() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720)
        let processorCalls = AtomicCounter()
        cam.setFrameProcessor(throttleHz: 0) { _, _ in
            processorCalls.increment()
        }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let calls = processorCalls.value
        let frames = stop.streamReports.first { $0.streamId == "cam_ego" }!.frameCount
        XCTAssertGreaterThanOrEqual(frames, 40)
        // The fast closure is essentially zero-cost; the gate should never
        // be busy by the time the next frame arrives, so calls ≈ frames.
        // Allow a small margin for the one-frame race where the very
        // first sample arrives before the host wires the processor.
        XCTAssertGreaterThanOrEqual(
            calls, frames - 3,
            "fast processor under-fired: \(calls) calls for \(frames) frames")
    }

    /// The frame processor must execute on `syncfield.camera.processor`,
    /// not on `syncfield.camera`. Verifies the off-queue dispatch is
    /// actually happening (and not silently degrading to inline calls).
    /// Captured via `__dispatch_queue_get_label` which is the canonical
    /// way to identify the current dispatch queue.
    func test_frame_processor_runs_on_dedicated_queue() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cam = iPhoneCameraStream(streamId: "cam_ego", videoSettings: .hd720)
        let observedLabels = StringBox()
        cam.setFrameProcessor(throttleHz: 0) { _, _ in
            let cLabel = __dispatch_queue_get_label(nil)
            observedLabels.append(String(cString: cLabel))
        }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(cam)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let labels = observedLabels.snapshot
        XCTAssertFalse(labels.isEmpty, "frame processor never fired")
        // Every invocation must have been on the processor queue. If even
        // one shows the capture queue label, the off-queue dispatch is
        // broken and the FPS-drop bug is back.
        let bad = labels.filter { $0 != "syncfield.camera.processor" }
        XCTAssertTrue(
            bad.isEmpty,
            "frame processor ran on the wrong queue: \(Set(bad))")
    }
}
#endif
