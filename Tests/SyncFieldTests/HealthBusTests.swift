// Tests/SyncFieldTests/HealthBusTests.swift
import XCTest
@testable import SyncField

final class HealthBusTests: XCTestCase {
    func test_multiple_subscribers_receive_same_events() async {
        let bus = HealthBus()
        let sub1 = bus.subscribe()
        let sub2 = bus.subscribe()

        Task {
            await bus.publish(.streamConnected(streamId: "a"))
            await bus.publish(.streamConnected(streamId: "b"))
            bus.finish()
        }

        var got1: [String] = []
        for await ev in sub1 {
            if case .streamConnected(let id) = ev { got1.append(id) }
        }
        var got2: [String] = []
        for await ev in sub2 {
            if case .streamConnected(let id) = ev { got2.append(id) }
        }
        XCTAssertEqual(got1, ["a", "b"])
        XCTAssertEqual(got2, ["a", "b"])
    }
}
