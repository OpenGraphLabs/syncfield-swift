import XCTest
@testable import SyncFieldInsta360

final class Insta360CoordinatorConfigTests: XCTestCase {

    override func tearDown() {
        // Reset shared instance between tests so we don't leak state.
        let c = Insta360CoordinatorConfig.shared
        c.autoReconnectEnabled = true
        c.radioGateEnabled = true
        c.backgroundBLEEnabled = true
        c.wakeUserPromptEnabled = true
        c.heartbeatIntervalMs = 2_000
        c.radioGateSlowHeartbeatIntervalMs = 8_000
        c.bleStrategyDuringWifi = .keepAlive
        c.wakeStallThresholdSeconds = 12
        c.persistentScanWindowCount = 3
        c.persistentScanWindowSeconds = 6
        c.persistentLastSeenThresholdSeconds = 90
        c.diagnosticsEnabled = false
        c.healthSnapshotIntervalMs = 5_000
        c.minLogLevel = .info
        c.apply()
        super.tearDown()
    }

    func testDefaultsMatchPlan() {
        let c = Insta360CoordinatorConfig.shared
        XCTAssertTrue(c.autoReconnectEnabled)
        XCTAssertTrue(c.radioGateEnabled)
        XCTAssertTrue(c.backgroundBLEEnabled)
        XCTAssertTrue(c.wakeUserPromptEnabled)
        XCTAssertEqual(c.heartbeatIntervalMs, 2_000)
        XCTAssertEqual(c.radioGateSlowHeartbeatIntervalMs, 8_000)
        XCTAssertEqual(c.bleStrategyDuringWifi, .keepAlive)
        XCTAssertEqual(c.wakeStallThresholdSeconds, 12)
        XCTAssertEqual(c.persistentScanWindowCount, 3)
        XCTAssertEqual(c.persistentLastSeenThresholdSeconds, 90)
        XCTAssertFalse(c.diagnosticsEnabled)
        XCTAssertFalse(c.scenarioMode)
    }

    func testApplyPropagatesLogLevelToInstaLog() {
        let c = Insta360CoordinatorConfig.shared
        c.minLogLevel = .warn
        c.apply()
        XCTAssertEqual(InstaLog.minLevel, .warn)

        c.minLogLevel = .debug
        c.apply()
        XCTAssertEqual(InstaLog.minLevel, .debug)
    }

    func testEnableScenarioModeFlipsAllRelevantToggles() {
        let c = Insta360CoordinatorConfig.shared
        XCTAssertFalse(c.scenarioMode)
        c.enableScenarioMode()
        XCTAssertTrue(c.scenarioMode)
        XCTAssertEqual(c.minLogLevel, .debug)
        XCTAssertEqual(InstaLog.minLevel, .debug)
    }
}
