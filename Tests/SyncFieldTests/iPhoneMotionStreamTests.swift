// Tests/SyncFieldTests/iPhoneMotionStreamTests.swift
#if os(iOS)
import XCTest
@testable import SyncField

final class iPhoneMotionStreamTests: XCTestCase {
    func test_records_about_100_samples_per_second() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = iPhoneMotionStream(streamId: "imu", rateHz: 100)
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await s.add(stream)
        try await s.connect()
        _ = try await s.startRecording()
        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
        let stop = try await s.stopRecording()
        _ = try await s.ingest { _ in }
        try await s.disconnect()

        let imu = stop.streamReports.first { $0.streamId == "imu" }!
        XCTAssertGreaterThan(imu.frameCount, 80)  // allow 20% scheduler jitter
    }
}
#endif
