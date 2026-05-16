import XCTest
@testable import SyncFieldInsta360

final class Insta360ConnectionHealthTests: XCTestCase {

    func testDefaultIsIdleAndEmpty() {
        let h = Insta360ConnectionHealth(bindingKey: "AAA")
        XCTAssertEqual(h.state, .idle)
        XCTAssertNil(h.role)
        XCTAssertNil(h.rssi)
        XCTAssertEqual(h.consecutiveHeartbeatMisses, 0)
        XCTAssertEqual(h.connectAttemptsThisSession, 0)
        XCTAssertEqual(h.dockHint, .unknown)
        XCTAssertFalse(h.wifiInFlight)
    }

    func testDictionaryOmitsNilFieldsAndPreservesEnumRawValues() {
        let h = Insta360ConnectionHealth(
            bindingKey: "AAA",
            role: "left",
            state: .bleReady,
            rssi: -67,
            consecutiveHeartbeatMisses: 0,
            connectAttemptsThisSession: 1,
            dockHint: .docked,
            wifiInFlight: false)

        let d = h.toDictionary()
        XCTAssertEqual(d["bindingKey"] as? String, "AAA")
        XCTAssertEqual(d["role"] as? String, "left")
        XCTAssertEqual(d["state"] as? String, "bleReady")
        XCTAssertEqual(d["rssi"] as? Int, -67)
        XCTAssertEqual(d["dockHint"] as? String, "docked")
        XCTAssertEqual(d["consecutiveHeartbeatMisses"] as? Int, 0)
        XCTAssertEqual(d["connectAttemptsThisSession"] as? Int, 1)
        XCTAssertEqual(d["wifiInFlight"] as? Bool, false)

        // Nil-able fields absent rather than represented as NSNull.
        XCTAssertNil(d["lastError"])
        XCTAssertNil(d["lastSeenAtMs"])
        XCTAssertNil(d["batteryPercent"])
    }

    func testDictionaryIncludesAllPopulatedOptionalFields() {
        let h = Insta360ConnectionHealth(
            bindingKey: "BBB",
            role: "right",
            state: .reconnecting,
            rssi: -72,
            lastSeenAtMs: 12_345,
            lastCommandSuccessAtMs: 12_000,
            consecutiveHeartbeatMisses: 2,
            connectAttemptsThisSession: 3,
            lastError: "CBError.peripheralDisconnected",
            lastErrorAtMs: 12_400,
            dockHint: .separated,
            dockHintLastUpdatedAtMs: 11_000,
            batteryPercent: 87,
            batteryCharging: false,
            wifiInFlight: false)

        let d = h.toDictionary()
        XCTAssertEqual(d["lastError"] as? String, "CBError.peripheralDisconnected")
        XCTAssertEqual(d["lastErrorAtMs"] as? UInt64, 12_400)
        XCTAssertEqual(d["batteryPercent"] as? Int, 87)
        XCTAssertEqual(d["batteryCharging"] as? Bool, false)
        XCTAssertEqual(d["dockHintLastUpdatedAtMs"] as? UInt64, 11_000)
    }
}
