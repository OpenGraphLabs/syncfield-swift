// Tests/SyncFieldTests/StreamCapabilitiesTests.swift
import XCTest
@testable import SyncField

final class StreamCapabilitiesTests: XCTestCase {
    func test_default_is_native_live_stream() {
        let c = StreamCapabilities()
        XCTAssertFalse(c.requiresIngest)
        XCTAssertTrue(c.producesFile)
        XCTAssertTrue(c.supportsPreciseTimestamps)
    }

    func test_json_uses_snake_case() throws {
        let c = StreamCapabilities(requiresIngest: true, producesFile: true,
                                   supportsPreciseTimestamps: false)
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(c)) as! [String: Any]
        XCTAssertEqual(Set(dict.keys),
                       ["requires_ingest", "produces_file",
                        "supports_precise_timestamps"])
    }
}
