import Foundation

/// Ordered non-blocking front-end for per-video-frame timestamp sidecars.
/// `flush()` is the segment boundary: every callback accepted before the
/// writer swap is durable before the old StreamWriter is closed.
final class StreamWriterPump {
    private let queue: DispatchQueue
    private let group = DispatchGroup()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func append(
        writer: StreamWriter,
        frame: Int,
        monotonicNs: UInt64,
        uncertaintyNs: UInt64
    ) {
        group.enter()
        queue.async {
            let semaphore = DispatchSemaphore(value: 0)
            Task { [writer] in
                try? await writer.append(
                    frame: frame,
                    monotonicNs: monotonicNs,
                    uncertaintyNs: uncertaintyNs)
                semaphore.signal()
            }
            semaphore.wait()
            self.group.leave()
        }
    }

    func flush() { group.wait() }
}
