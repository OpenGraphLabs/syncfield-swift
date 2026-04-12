// Tests/SyncFieldTests/SessionStateTests.swift
import XCTest
@testable import SyncField

final class SessionStateTests: XCTestCase {
    func test_all_cases_are_distinct_and_codable() throws {
        let all: [SessionState] = [.idle, .connected, .recording, .stopping, .ingesting]
        let encoded = try JSONEncoder().encode(all)
        let decoded = try JSONDecoder().decode([SessionState].self, from: encoded)
        XCTAssertEqual(decoded, all)
    }
}
