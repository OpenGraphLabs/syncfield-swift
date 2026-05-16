import XCTest
@testable import SyncFieldInsta360

final class Insta360ConnectionCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InstaLog.mirrorToNSLog = false
        InstaLog.minLevel = .warn
    }

    override func tearDown() async throws {
        InstaLog.mirrorToNSLog = true
        // Clean shared coordinator between tests.
        await Insta360ConnectionCoordinator.shared.detachAll()
    }

    func testAttachCreatesSupervisorAndIsIdempotent() async {
        let coord = Insta360ConnectionCoordinator.shared
        let sup1 = await coord.attach(bindingKey: "AAA", role: "left")
        let sup2 = await coord.attach(bindingKey: "AAA", role: "left")
        XCTAssertTrue(sup1 === sup2)
        let attached = await coord.isAttached(bindingKey: "AAA")
        XCTAssertTrue(attached)
    }

    func testDetachRemovesSupervisor() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "AAA", role: "left")
        await coord.detach(bindingKey: "AAA")
        let attached = await coord.isAttached(bindingKey: "AAA")
        XCTAssertFalse(attached)
    }

    func testStateObserverReceivesTransitions() async {
        let coord = Insta360ConnectionCoordinator.shared
        let received = expectation(description: "observer received state event")
        received.expectedFulfillmentCount = 1
        received.assertForOverFulfill = false
        await coord.setStateObserver { event in
            if event.to == .searching {
                received.fulfill()
            }
        }
        _ = await coord.attach(bindingKey: "BBB", role: "right")
        await fulfillment(of: [received], timeout: 1)
    }

    func testFeedRoutesEventToCorrectSupervisor() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "L", role: "left")
        _ = await coord.attach(bindingKey: "R", role: "right")
        await coord.feed(bindingKey: "L", event: .scanHit(rssi: -65))
        await coord.feed(bindingKey: "L", event: .readinessProbeAck(elapsedMs: 100))
        let healthL = await coord.health(bindingKey: "L")
        let healthR = await coord.health(bindingKey: "R")
        let stateL = healthL?.state
        let stateR = healthR?.state
        XCTAssertEqual(stateL, .bleReady)
        XCTAssertEqual(stateR, .searching)  // attached but no scan hit
    }

    func testForceReconnectFeedsForceEvent() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "AAA", role: "left")
        // Drive to lost first
        await coord.feed(bindingKey: "AAA", event: .scanWindowClosedNoHit)
        await coord.feed(bindingKey: "AAA", event: .scanWindowClosedNoHit)
        await coord.feed(bindingKey: "AAA", event: .scanWindowClosedNoHit)
        let lostState = await coord.health(bindingKey: "AAA")?.state
        XCTAssertEqual(lostState, .lost)
        await coord.forceReconnect(bindingKey: "AAA")
        let searchingState = await coord.health(bindingKey: "AAA")?.state
        XCTAssertEqual(searchingState, .searching)
    }

    func testAllHealthReturnsAllAttachedCameras() async {
        let coord = Insta360ConnectionCoordinator.shared
        _ = await coord.attach(bindingKey: "L", role: "left")
        _ = await coord.attach(bindingKey: "R", role: "right")
        let all = await coord.allHealth()
        XCTAssertEqual(Set(all.keys), Set(["L", "R"]))
    }
}
