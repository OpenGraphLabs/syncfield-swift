import XCTest
@testable import SyncField

final class SyncSessionTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncfield_test_\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testBasicSessionFlow() throws {
        let session = SyncSession(hostId: "rig_01", outputDir: tempDir)
        let sp = try session.start()
        XCTAssertEqual(sp.hostId, "rig_01")
        XCTAssertGreaterThan(sp.monotonicNs, 0)

        for i in 0..<5 {
            try session.stamp("cam_left", frameNumber: i)
            try session.stamp("cam_right", frameNumber: i)
        }

        let counts = try session.stop()
        XCTAssertEqual(counts, ["cam_left": 5, "cam_right": 5])

        // Check output files
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("sync_point.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("cam_left.timestamps.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("cam_right.timestamps.jsonl").path))

        // Verify JSONL content
        let content = try String(contentsOf: tempDir.appendingPathComponent("cam_left.timestamps.jsonl"))
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)

        let first = try JSONSerialization.jsonObject(with: lines[0].data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(first["frame_number"] as? Int, 0)
        XCTAssertEqual(first["clock_source"] as? String, "host_monotonic")
        XCTAssertEqual(first["clock_domain"] as? String, "rig_01")
    }

    func testStartCreatesOutputDir() throws {
        let session = SyncSession(hostId: "test_host", outputDir: tempDir)
        try session.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
        _ = try session.stop()
    }

    func testDoubleStartThrows() throws {
        let session = SyncSession(hostId: "test_host", outputDir: tempDir)
        try session.start()
        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertEqual(error as? SyncFieldError, .sessionAlreadyStarted)
        }
        _ = try session.stop()
    }

    func testStampBeforeStartThrows() {
        let session = SyncSession(hostId: "test_host", outputDir: tempDir)
        XCTAssertThrowsError(try session.stamp("cam", frameNumber: 0)) { error in
            XCTAssertEqual(error as? SyncFieldError, .sessionNotStarted)
        }
    }

    func testSessionReuse() throws {
        let session = SyncSession(hostId: "h", outputDir: tempDir)

        // First session
        try session.start()
        try session.stamp("s1", frameNumber: 0)
        let counts1 = try session.stop()
        XCTAssertEqual(counts1["s1"], 1)

        // Second session — should work with clean state
        try session.start()
        try session.stamp("s2", frameNumber: 0)
        try session.stamp("s2", frameNumber: 1)
        let counts2 = try session.stop()
        XCTAssertEqual(counts2["s2"], 2)
        XCTAssertNil(counts2["s1"])  // s1 should not appear in second session
    }

    // MARK: - SyncPoint

    func testSyncPointCaptured() throws {
        let session = SyncSession(hostId: "rig_01", outputDir: tempDir)
        let sp = try session.start()
        XCTAssertEqual(sp.hostId, "rig_01")
        XCTAssertGreaterThan(sp.monotonicNs, 0)
        XCTAssertGreaterThan(sp.wallClockNs, 0)
        XCTAssertEqual(sp.timestampMs, sp.wallClockNs / 1_000_000)
        XCTAssertFalse(sp.isoDatetime.isEmpty)
        _ = try session.stop()
    }

    func testSyncPointJsonContent() throws {
        let session = SyncSession(hostId: "rig_02", outputDir: tempDir)
        try session.start()
        _ = try session.stop()

        let data = try Data(contentsOf: tempDir.appendingPathComponent("sync_point.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["sdk_version"] as? String, syncFieldVersion)
        XCTAssertEqual(json["host_id"] as? String, "rig_02")
        XCTAssertNotNil(json["monotonic_ns"])
        XCTAssertNotNil(json["wall_clock_ns"])
        XCTAssertNotNil(json["iso_datetime"])
        XCTAssertNotNil(json["timestamp_ms"])
    }

    // MARK: - stamp()

    func testTimestampsAreMonotonicallyIncreasing() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        for i in 0..<100 {
            try session.stamp("stream", frameNumber: i)
        }

        _ = try session.stop()

        let content = try String(contentsOf: tempDir.appendingPathComponent("stream.timestamps.jsonl"))
        let lines = content.split(separator: "\n")
        let timestamps: [UInt64] = try lines.map { line in
            let json = try JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
            return json["capture_ns"] as! UInt64
        }

        for i in 1..<timestamps.count {
            XCTAssertGreaterThanOrEqual(timestamps[i], timestamps[i - 1],
                "Non-monotonic: \(timestamps[i - 1]) -> \(timestamps[i])")
        }
    }

    func testStampReturnsCaptureNs() throws {
        let session = SyncSession(hostId: "h", outputDir: tempDir)
        try session.start()
        let ns = try session.stamp("s", frameNumber: 0)
        XCTAssertGreaterThan(ns, 0)
        _ = try session.stop()
    }

    func testStampWithPreCapturedNs() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        let preCaptured = MonotonicClock.now()
        let result = try session.stamp("cam", frameNumber: 0, captureNs: preCaptured)

        _ = try session.stop()

        XCTAssertEqual(result, preCaptured)

        let content = try String(contentsOf: tempDir.appendingPathComponent("cam.timestamps.jsonl"))
        let entry = try JSONSerialization.jsonObject(with: content.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(entry["capture_ns"] as? UInt64, preCaptured)
    }

    func testCustomUncertainty() throws {
        let session = SyncSession(hostId: "h", outputDir: tempDir)
        try session.start()
        try session.stamp("imu", frameNumber: 0, uncertaintyNs: 1_000_000)
        _ = try session.stop()

        let content = try String(contentsOf: tempDir.appendingPathComponent("imu.timestamps.jsonl"))
        let line = try JSONSerialization.jsonObject(with: content.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(line["uncertainty_ns"] as? UInt64, 1_000_000)
    }

    // MARK: - record()

    func testRecordBasicFlow() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        for i in 0..<3 {
            try session.record("imu", frameNumber: i, channels: ["x": Double(i)])
        }

        _ = try session.stop()

        let tsPath = tempDir.appendingPathComponent("imu.timestamps.jsonl")
        let sensorPath = tempDir.appendingPathComponent("imu.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tsPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sensorPath.path))

        let tsLines = try String(contentsOf: tsPath).split(separator: "\n")
        let sensorLines = try String(contentsOf: sensorPath).split(separator: "\n")
        XCTAssertEqual(tsLines.count, 3)
        XCTAssertEqual(sensorLines.count, 3)
    }

    func testRecordSensorJsonlContent() throws {
        let session = SyncSession(hostId: "rig_01", outputDir: tempDir)
        try session.start()

        try session.record("imu", frameNumber: 0, channels: ["accel_x": 0.5, "accel_y": -1.2])

        _ = try session.stop()

        let content = try String(contentsOf: tempDir.appendingPathComponent("imu.jsonl"))
        let line = try JSONSerialization.jsonObject(with: content.data(using: .utf8)!) as! [String: Any]
        let channels = line["channels"] as! [String: Any]
        XCTAssertEqual(channels["accel_x"] as? Double, 0.5)
        XCTAssertEqual(channels["accel_y"] as? Double, -1.2)
        XCTAssertGreaterThan(line["capture_ns"] as! UInt64, 0)
        XCTAssertEqual(line["frame_number"] as? Int, 0)
        XCTAssertEqual(line["clock_source"] as? String, "host_monotonic")
        XCTAssertEqual(line["clock_domain"] as? String, "rig_01")
        XCTAssertEqual(line["uncertainty_ns"] as? UInt64, 5_000_000)
    }

    func testRecordTimestampsMatchSensor() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        for i in 0..<5 {
            try session.record("sensor", frameNumber: i, channels: ["v": Double(i)])
        }

        _ = try session.stop()

        let tsLines = try String(contentsOf: tempDir.appendingPathComponent("sensor.timestamps.jsonl"))
            .split(separator: "\n")
        let sensorLines = try String(contentsOf: tempDir.appendingPathComponent("sensor.jsonl"))
            .split(separator: "\n")

        for (tsRaw, sensorRaw) in zip(tsLines, sensorLines) {
            let ts = try JSONSerialization.jsonObject(with: tsRaw.data(using: .utf8)!) as! [String: Any]
            let sensor = try JSONSerialization.jsonObject(with: sensorRaw.data(using: .utf8)!) as! [String: Any]
            XCTAssertEqual(ts["capture_ns"] as? UInt64, sensor["capture_ns"] as? UInt64)
            XCTAssertEqual(ts["frame_number"] as? Int, sensor["frame_number"] as? Int)
        }
    }

    func testRecordReturnsCaptureNs() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()
        let result = try session.record("imu", frameNumber: 0, channels: ["x": 1.0])
        _ = try session.stop()
        XCTAssertGreaterThan(result, 0)
    }

    func testRecordBeforeStartThrows() {
        let session = SyncSession(hostId: "h", outputDir: tempDir)
        XCTAssertThrowsError(
            try session.record("imu", frameNumber: 0, channels: ["x": 1.0])
        ) { error in
            XCTAssertEqual(error as? SyncFieldError, .sessionNotStarted)
        }
    }

    func testRecordWithPreCapturedNs() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        let preCaptured = MonotonicClock.now()
        let result = try session.record(
            "imu", frameNumber: 0, channels: ["x": 1.0], captureNs: preCaptured)

        _ = try session.stop()

        XCTAssertEqual(result, preCaptured)

        // Both files should have the same pre-captured timestamp
        let tsContent = try String(contentsOf: tempDir.appendingPathComponent("imu.timestamps.jsonl"))
        let tsLine = try JSONSerialization.jsonObject(with: tsContent.data(using: .utf8)!) as! [String: Any]
        let sensorContent = try String(contentsOf: tempDir.appendingPathComponent("imu.jsonl"))
        let sensorLine = try JSONSerialization.jsonObject(with: sensorContent.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(tsLine["capture_ns"] as? UInt64, preCaptured)
        XCTAssertEqual(sensorLine["capture_ns"] as? UInt64, preCaptured)
    }

    func testRecordNestedChannels() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        let handState: [String: Any] = [
            "joints": [
                "wrist": [0.1, 0.2, 0.3],
                "thumb_tip": [0.4, 0.5, 0.6],
            ] as [String: Any],
            "gestures": ["pinch": 0.95, "fist": 0.02] as [String: Any],
            "finger_angles": [12.5, 45.0, 30.0, 15.0, 5.0],
        ]
        try session.record("hand_tracker", frameNumber: 0, channels: handState)

        _ = try session.stop()

        let content = try String(contentsOf: tempDir.appendingPathComponent("hand_tracker.jsonl"))
        let line = try JSONSerialization.jsonObject(with: content.data(using: .utf8)!) as! [String: Any]
        let channels = line["channels"] as! [String: Any]
        let joints = channels["joints"] as! [String: Any]
        XCTAssertEqual(joints["wrist"] as! [Double], [0.1, 0.2, 0.3])
        let gestures = channels["gestures"] as! [String: Any]
        XCTAssertEqual(gestures["pinch"] as? Double, 0.95)
        XCTAssertEqual(channels["finger_angles"] as! [Double], [12.5, 45.0, 30.0, 15.0, 5.0])
    }

    // MARK: - link()

    func testLinkBasic() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()
        session.link("cam_left", path: "/data/video.mp4")
        _ = try session.stop()

        let data = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let streams = manifest["streams"] as! [String: Any]
        XCTAssertNotNil(streams["cam_left"])
        let camLeft = streams["cam_left"] as! [String: Any]
        XCTAssertEqual(camLeft["path"] as? String, "/data/video.mp4")
    }

    func testLinkWithStamp() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()

        for i in 0..<3 {
            try session.stamp("cam_left", frameNumber: i)
        }
        session.link("cam_left", path: "/data/video.mp4")

        _ = try session.stop()

        let data = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let streams = manifest["streams"] as! [String: Any]
        let entry = streams["cam_left"] as! [String: Any]
        XCTAssertEqual(entry["type"] as? String, "video")
        XCTAssertEqual(entry["path"] as? String, "/data/video.mp4")
        XCTAssertEqual(entry["timestamps_path"] as? String, "cam_left.timestamps.jsonl")
    }

    // MARK: - Manifest

    func testManifestWrittenOnStop() throws {
        let session = SyncSession(hostId: "h1", outputDir: tempDir)
        try session.start()
        try session.stamp("cam", frameNumber: 0)
        _ = try session.stop()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("manifest.json").path))
    }

    func testManifestStreamTypes() throws {
        let session = SyncSession(hostId: "h", outputDir: tempDir)
        try session.start()
        try session.stamp("cam", frameNumber: 0)
        try session.record("imu", frameNumber: 0, channels: ["x": 1.0])
        _ = try session.stop()

        let data = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let streams = manifest["streams"] as! [String: Any]

        let cam = streams["cam"] as! [String: Any]
        XCTAssertEqual(cam["type"] as? String, "video")
        XCTAssertNil(cam["sensor_path"])

        let imu = streams["imu"] as! [String: Any]
        XCTAssertEqual(imu["type"] as? String, "sensor")
        XCTAssertEqual(imu["sensor_path"] as? String, "imu.jsonl")
    }

    func testManifestMixedStreams() throws {
        let session = SyncSession(hostId: "rig_01", outputDir: tempDir)
        try session.start()

        // Video stream: stamp + link
        for i in 0..<5 {
            try session.stamp("cam_left", frameNumber: i)
        }
        session.link("cam_left", path: "/data/cam_left.mp4")

        // Sensor stream: record
        for i in 0..<10 {
            try session.record("imu", frameNumber: i, channels: ["ax": Double(i), "ay": 0.0])
        }

        let counts = try session.stop()

        let data = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(manifest["host_id"] as? String, "rig_01")
        XCTAssertNotNil(manifest["sdk_version"])

        let streams = manifest["streams"] as! [String: Any]

        // Video stream
        let cam = streams["cam_left"] as! [String: Any]
        XCTAssertEqual(cam["type"] as? String, "video")
        XCTAssertEqual(cam["path"] as? String, "/data/cam_left.mp4")
        XCTAssertEqual(cam["timestamps_path"] as? String, "cam_left.timestamps.jsonl")
        XCTAssertEqual(cam["frame_count"] as? Int, 5)

        // Sensor stream
        let imu = streams["imu"] as! [String: Any]
        XCTAssertEqual(imu["type"] as? String, "sensor")
        XCTAssertEqual(imu["sensor_path"] as? String, "imu.jsonl")
        XCTAssertEqual(imu["timestamps_path"] as? String, "imu.timestamps.jsonl")
        XCTAssertEqual(imu["frame_count"] as? Int, 10)

        // Counts from stop()
        XCTAssertEqual(counts["cam_left"], 5)
        XCTAssertEqual(counts["imu"], 10)
    }

    // MARK: - Thread safety

    func testConcurrentStamps() throws {
        let session = SyncSession(hostId: "mt", outputDir: tempDir)
        try session.start()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.stamp", attributes: .concurrent)
        let errors = NSMutableArray()  // thread-safe via ObjC atomicity

        for streamIdx in 0..<4 {
            group.enter()
            queue.async {
                do {
                    for i in 0..<200 {
                        try session.stamp("s\(streamIdx)", frameNumber: i)
                    }
                } catch {
                    errors.add(error)
                }
                group.leave()
            }
        }

        group.wait()
        let counts = try session.stop()

        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(counts.count, 4)
        for (_, count) in counts {
            XCTAssertEqual(count, 200)
        }
    }

    func testConcurrentRecords() throws {
        let session = SyncSession(hostId: "mt", outputDir: tempDir)
        try session.start()

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.record", attributes: .concurrent)
        let errors = NSMutableArray()

        for streamIdx in 0..<4 {
            group.enter()
            queue.async {
                do {
                    for i in 0..<200 {
                        try session.record(
                            "s\(streamIdx)", frameNumber: i,
                            channels: ["v": Double(i)])
                    }
                } catch {
                    errors.add(error)
                }
                group.leave()
            }
        }

        group.wait()
        let counts = try session.stop()

        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(counts.count, 4)
        for (_, count) in counts {
            XCTAssertEqual(count, 200)
        }
    }

    // MARK: - String path initializer

    func testStringPathInitializer() throws {
        let session = SyncSession(hostId: "h", outputDir: tempDir.path)
        try session.start()
        try session.stamp("s", frameNumber: 0)
        _ = try session.stop()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("s.timestamps.jsonl").path))
    }
}

// MARK: - Equatable for error assertions

extension SyncFieldError: Equatable {
    public static func == (lhs: SyncFieldError, rhs: SyncFieldError) -> Bool {
        switch (lhs, rhs) {
        case (.sessionAlreadyStarted, .sessionAlreadyStarted): return true
        case (.sessionNotStarted, .sessionNotStarted): return true
        case (.writerNotOpen(let a), .writerNotOpen(let b)): return a == b
        default: return false
        }
    }
}
