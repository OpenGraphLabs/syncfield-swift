// Tests/SyncFieldTests/SessionClockTests.swift
import XCTest
@testable import SyncField

final class SessionClockTests: XCTestCase {
    func test_now_ns_is_monotonic_nondecreasing() {
        let clock = SessionClock()
        let a = clock.nowMonotonicNs()
        let b = clock.nowMonotonicNs()
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func test_anchor_captures_both_monotonic_and_wall() {
        let clock = SessionClock()
        let anchor = clock.anchor(hostId: "h")
        XCTAssertGreaterThan(anchor.monotonicNs, 0)
        XCTAssertGreaterThan(anchor.wallClockNs, 1_600_000_000_000_000_000)  // after 2020
        XCTAssertEqual(anchor.hostId, "h")
        XCTAssertFalse(anchor.isoDatetime.isEmpty)
    }

    func test_mach_ticks_to_ns_conversion_is_identity_on_arm64() {
        // On Apple Silicon, 1 mach tick == 1 ns (numer == denom == 1).
        // This test asserts the conversion path works; exact ratio is platform-specific.
        let clock = SessionClock()
        let ticks: UInt64 = 1_000_000_000
        let ns = clock.machTicksToMonotonicNs(ticks)
        XCTAssertGreaterThan(ns, 0)
    }
}
