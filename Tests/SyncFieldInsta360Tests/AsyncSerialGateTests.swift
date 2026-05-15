import XCTest
@testable import SyncFieldInsta360

final class AsyncSerialGateTests: XCTestCase {
    func testWithLockSerializesConcurrentOperations() async {
        let gate = AsyncSerialGate()
        let tracker = ActiveTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.withLock {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.leave()
                    }
                }
            }
        }

        let (activeCount, maxActiveCount) = await tracker.snapshot()
        XCTAssertEqual(maxActiveCount, 1)
        XCTAssertEqual(activeCount, 0)
    }
}

private actor ActiveTracker {
    private var activeCount = 0
    private var maxActiveCount = 0

    func enter() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }

    func snapshot() -> (activeCount: Int, maxActiveCount: Int) {
        (activeCount, maxActiveCount)
    }
}
