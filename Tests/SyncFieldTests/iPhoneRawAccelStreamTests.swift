#if os(iOS)
import CoreMotion
import XCTest
@testable import SyncField

final class iPhoneRawAccelStreamTests: XCTestCase {
    func test_records_raw_accelerometer_samples() async throws {
        guard CMMotionManager().isAccelerometerAvailable else {
            throw XCTSkip("raw accelerometer unavailable on this device")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = iPhoneRawAccelStream(streamId: "imu_accel_raw", rateHz: 100)
        let session = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await session.add(stream)
        try await session.connect()
        _ = try await session.startRecording()
        try await Task.sleep(nanoseconds: 500_000_000)
        let stop = try await session.stopRecording()
        _ = try await session.ingest { _ in }
        try await session.disconnect()

        let report = try XCTUnwrap(stop.streamReports.first {
            $0.streamId == "imu_accel_raw"
        })
        XCTAssertGreaterThan(report.frameCount, 0)
    }
}
#endif
