// Sources/SyncField/Streams/FrameProcessorGate.swift
import Foundation

/// Serial off-queue dispatch with drop-on-busy semantics. The camera
/// sample-buffer delegate uses this to invoke a host-supplied frame
/// processor without blocking the capture queue. When the previous unit
/// of work is still running, new `tryEnqueue(_:)` calls return `false`
/// and the caller is expected to drop the frame rather than queue it —
/// matching the upstream `alwaysDiscardsLateVideoFrames=true` policy on
/// `AVCaptureVideoDataOutput`, so backpressure never builds up.
///
/// The internal queue is serial (`.userInitiated`). Hosts that wrap a
/// stateful detector (MediaPipe `.video` mode, Vision tracking) are
/// guaranteed serial invocation by construction — no extra locking
/// required on their side.
final class FrameProcessorGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var busy = false

    init(label: String, qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    /// Dispatch `work` to the internal serial queue if no prior unit is
    /// in flight. Returns `true` when the work was scheduled, `false`
    /// when the gate was busy and the work was *not* scheduled (the
    /// caller's expected response is to drop, not retry).
    @discardableResult
    func tryEnqueue(_ work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()

        queue.async { [weak self] in
            work()
            guard let self else { return }
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
        }
        return true
    }

    /// Block the caller until any in-flight work on the internal queue
    /// has completed. Use during teardown (`stopRecording`,
    /// `disconnect`) so the last processor callback finishes before the
    /// surrounding stream releases assetWriter / orchestrator state it
    /// might reference. Relies on serial-queue ordering: a `sync` block
    /// submitted to a serial queue runs *after* all previously queued
    /// async work.
    func drain() {
        queue.sync { /* serial-queue barrier */ }
    }

    /// True while a unit of work is in flight. Diagnostic only; the
    /// `tryEnqueue` return value is the authoritative signal for
    /// scheduling decisions.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }
}
