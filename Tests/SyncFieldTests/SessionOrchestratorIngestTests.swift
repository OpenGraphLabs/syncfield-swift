// Tests/SyncFieldTests/SessionOrchestratorIngestTests.swift
import XCTest
@testable import SyncField

final class SessionOrchestratorIngestTests: XCTestCase {
    func test_partial_ingest_failure_is_reported_not_raised() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let ok  = MockStream(streamId: "ok")
        let bad = MockStream(streamId: "bad")
        await bad.setFailAt(.ingest)
        try await s.add(ok)
        try await s.add(bad)

        try await s.connect()
        _ = try await s.startRecording()
        _ = try await s.stopRecording()
        let report = try await s.ingest { _ in }

        if case .success = report.streamResults["ok"]! { /* ok */ } else { XCTFail() }
        if case .failure = report.streamResults["bad"]! { /* ok */ } else { XCTFail() }
    }
}
