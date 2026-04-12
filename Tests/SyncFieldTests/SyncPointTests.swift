// Tests/SyncFieldTests/SyncPointTests.swift
import XCTest
@testable import SyncField

final class SyncPointTests: XCTestCase {
    func test_round_trip_json_preserves_all_fields() throws {
        let sp = SyncPoint(
            sdkVersion: "0.2.0",
            monotonicNs: 12_345_678,
            wallClockNs: 1_700_000_000_000_000_000,
            hostId: "iphone_ego",
            isoDatetime: "2026-04-11T15:29:30Z"
        )
        let data = try JSONEncoder().encode(sp)
        let decoded = try JSONDecoder().decode(SyncPoint.self, from: data)
        XCTAssertEqual(decoded, sp)
    }

    func test_json_keys_match_server_contract() throws {
        let sp = SyncPoint(sdkVersion: "0.2.0", monotonicNs: 1, wallClockNs: 2,
                           hostId: "h", isoDatetime: "d")
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sp)) as! [String: Any]
        XCTAssertEqual(Set(dict.keys), ["sdk_version", "monotonic_ns",
                                        "wall_clock_ns", "host_id", "iso_datetime"])
    }
}
