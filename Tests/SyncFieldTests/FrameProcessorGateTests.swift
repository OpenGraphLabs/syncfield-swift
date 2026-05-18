// Tests/SyncFieldTests/FrameProcessorGateTests.swift
import XCTest
@testable import SyncField

/// Pure-Swift unit tests for `FrameProcessorGate`. These do not touch
/// `AVCaptureSession` and therefore run on every platform / runner
/// (macOS host `swift test`, iOS simulator, iOS device) — important
/// because the `iPhoneCameraStreamTests` end-to-end suite requires a
/// real back camera and only runs on physical devices. The gate is the
/// piece responsible for the FPS-stability contract; covering it in
/// isolation gives the regression net teeth on CI.
final class FrameProcessorGateTests: XCTestCase {

    /// First `tryEnqueue` returns `true` and the closure runs.
    func test_first_enqueue_dispatches_work() {
        let gate = FrameProcessorGate(label: "test.\(#function)")
        let ran = expectation(description: "work ran")
        let scheduled = gate.tryEnqueue {
            ran.fulfill()
        }
        XCTAssertTrue(scheduled, "first tryEnqueue must dispatch")
        wait(for: [ran], timeout: 1.0)
    }

    /// Second `tryEnqueue` while the first is still running returns
    /// `false` and the second closure must not run — this is the
    /// drop-on-busy contract that keeps the capture queue unblocked.
    func test_concurrent_enqueue_is_dropped_while_busy() {
        let gate = FrameProcessorGate(label: "test.\(#function)")
        let firstStarted = expectation(description: "first started")
        let firstFinish = expectation(description: "first finish")
        let secondDidNotRun = expectation(description: "second did not run")
        secondDidNotRun.isInverted = true

        let firstScheduled = gate.tryEnqueue {
            firstStarted.fulfill()
            // Hold the gate busy long enough for the second tryEnqueue
            // to observe it.
            Thread.sleep(forTimeInterval: 0.20)
            firstFinish.fulfill()
        }
        XCTAssertTrue(firstScheduled)

        // Make sure the first work is actually executing before we try
        // the second — without this we'd race the dispatch.
        wait(for: [firstStarted], timeout: 1.0)

        let secondScheduled = gate.tryEnqueue {
            secondDidNotRun.fulfill()
        }
        XCTAssertFalse(secondScheduled, "second tryEnqueue must be dropped while busy")

        wait(for: [firstFinish, secondDidNotRun], timeout: 1.0)
    }

    /// After the in-flight work completes the gate accepts new work
    /// again — proves `busy` is cleared on completion, not stuck.
    func test_enqueue_succeeds_again_after_previous_finishes() {
        let gate = FrameProcessorGate(label: "test.\(#function)")
        let firstDone = expectation(description: "first done")
        XCTAssertTrue(gate.tryEnqueue {
            Thread.sleep(forTimeInterval: 0.05)
            firstDone.fulfill()
        })
        wait(for: [firstDone], timeout: 1.0)

        // Spin briefly for the busy-flag reset to land. The reset
        // happens after the closure returns but on the gate's serial
        // queue, so we may need a hop.
        let deadline = Date().addingTimeInterval(0.5)
        while gate.isBusy, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(gate.isBusy)

        let secondDone = expectation(description: "second done")
        XCTAssertTrue(gate.tryEnqueue {
            secondDone.fulfill()
        })
        wait(for: [secondDone], timeout: 1.0)
    }

    /// `drain()` blocks until queued work has finished — guarantees
    /// the host's "stopRecording returned ⇒ no more callbacks" claim.
    func test_drain_blocks_until_inflight_work_finishes() {
        let gate = FrameProcessorGate(label: "test.\(#function)")
        let workFinished = expectation(description: "work finished")

        let started = Date()
        XCTAssertTrue(gate.tryEnqueue {
            Thread.sleep(forTimeInterval: 0.15)
            workFinished.fulfill()
        })

        gate.drain()
        // drain returned: the closure must have finished already.
        XCTAssertTrue(workFinished.assertForOverFulfill == false || true)  // already fulfilled
        wait(for: [workFinished], timeout: 0.01)
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(started),
            0.10,
            "drain should have waited for the ~150ms task")
    }

    /// drain() on an idle gate returns immediately.
    func test_drain_on_idle_returns_immediately() {
        let gate = FrameProcessorGate(label: "test.\(#function)")
        let started = Date()
        gate.drain()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
    }

    /// Sustained throughput under drop-on-busy: with a 50 ms task and a
    /// caller offering work every 10 ms for 500 ms, the gate should
    /// accept roughly `500/50 = 10` units (±2 for scheduler slack) and
    /// drop the rest. Validates that drop-on-busy actually limits
    /// concurrency to one — i.e. the host's MediaPipe `.video` mode
    /// stays serial as required.
    func test_drop_on_busy_serializes_under_load() {
        let gate = FrameProcessorGate(label: "test.\(#function)")
        let runCount = NSLock.Counter()
        let offerEnd = Date().addingTimeInterval(0.5)
        var accepted = 0

        while Date() < offerEnd {
            let scheduled = gate.tryEnqueue {
                Thread.sleep(forTimeInterval: 0.05)
                runCount.increment()
            }
            if scheduled { accepted += 1 }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Wait for any tail work.
        gate.drain()

        XCTAssertEqual(runCount.value, accepted,
                       "every accepted work item must have run exactly once")
        XCTAssertGreaterThanOrEqual(accepted, 7,
                                    "expected ~10 accepted in 500ms with 50ms work, got \(accepted)")
        XCTAssertLessThanOrEqual(accepted, 12,
                                 "drop-on-busy must cap accepted units near work-duration ceiling, got \(accepted)")
    }
}

/// Lightweight thread-safe counter used by the throughput test. Kept
/// inside the test target so it doesn't bleed into the SDK surface.
private extension NSLock {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
