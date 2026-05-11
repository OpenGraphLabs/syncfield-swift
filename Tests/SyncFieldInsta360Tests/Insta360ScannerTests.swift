import XCTest
@testable import SyncFieldInsta360

final class Insta360ScannerTests: XCTestCase {
    func test_shouldEmitDevice_acceptsGoName() {
        XCTAssertTrue(Insta360Scanner.shouldEmitDevice(name: "GO 3S 6GUCEB"))
    }

    func test_shouldEmitDevice_rejectsNonGo() {
        XCTAssertFalse(Insta360Scanner.shouldEmitDevice(name: "OGLO 100"))
    }

    func test_shouldEmitDevice_rejectsNil() {
        XCTAssertFalse(Insta360Scanner.shouldEmitDevice(name: nil))
    }

    func test_shouldEmitDevice_caseInsensitive() {
        XCTAssertTrue(Insta360Scanner.shouldEmitDevice(name: "go 3s lowercase"))
    }

    func test_shouldAcceptDevice_rejectsExcludedUUID() {
        XCTAssertFalse(Insta360BLEController.shouldAcceptDevice(
            name: "GO 3S A",
            uuid: "AAAA-0005",
            excluding: ["AAAA-0005"]))
    }

    func test_withTimeout_successReturnsValueBeforeDeadline() async throws {
        let value = try await Insta360BLEController.withTimeout(seconds: 1.0) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    func test_withTimeout_throwsTimeoutWhenOperationExceedsDeadline() async {
        do {
            _ = try await Insta360BLEController.withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return 0
            }
            XCTFail("expected timeout error")
        } catch let Insta360Error.commandFailed(message) {
            XCTAssertTrue(message.contains("timed out"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
