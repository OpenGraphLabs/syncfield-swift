// Tests/SyncFieldTests/SessionLogWriterTests.swift
import XCTest
@testable import SyncField

final class SessionLogWriterTests: XCTestCase {
    func test_every_entry_is_immediately_visible_on_disk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("session.log")
        let log = try await SessionLogWriter(url: url)
        try await log.append(kind: "state", detail: "idle->connected")

        let content = try String(contentsOf: url)
        XCTAssertTrue(content.contains("state"))
        XCTAssertTrue(content.contains("idle->connected"))

        try await log.append(kind: "health", detail: "tactile_left dropped 2")
        try await log.close()

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }
}
