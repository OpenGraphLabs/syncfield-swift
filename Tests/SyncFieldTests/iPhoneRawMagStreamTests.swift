#if os(iOS)
import CoreMotion
import XCTest
@testable import SyncField

final class iPhoneRawMagStreamTests: XCTestCase {
    func test_records_raw_magnetometer_samples() async throws {
        guard CMMotionManager().isMagnetometerAvailable else {
            throw XCTSkip("raw magnetometer unavailable on this device")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = iPhoneRawMagStream(streamId: "imu_mag_raw", rateHz: 50)
        let session = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        try await session.add(stream)
        try await session.connect()
        _ = try await session.startRecording()
        try await Task.sleep(nanoseconds: 500_000_000)
        let stop = try await session.stopRecording()
        _ = try await session.ingest { _ in }
        try await session.disconnect()

        let report = try XCTUnwrap(stop.streamReports.first {
            $0.streamId == "imu_mag_raw"
        })
        XCTAssertGreaterThan(report.frameCount, 0)
    }
}
#endif
