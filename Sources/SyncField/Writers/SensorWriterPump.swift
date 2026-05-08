import Foundation

/// Non-blocking front-end for high-rate CoreMotion callbacks.
///
/// CoreMotion invokes IMU callbacks on its own operation queue. Awaiting the
/// actor-backed `SensorWriter` from that callback can throttle delivery. This
/// pump lets the callback enqueue and return immediately while a dedicated
/// serial queue preserves JSONL write order and `flush()` gives stopRecording
/// a deterministic drain point.
final class SensorWriterPump {
    private let queue: DispatchQueue
    private let group = DispatchGroup()

    init(label: String) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func append(
        writer: SensorWriter,
        frame: Int,
        monotonicNs: UInt64,
        channels: [String: Any],
        deviceTimestampNs: UInt64? = nil
    ) {
        group.enter()
        queue.async {
            let semaphore = DispatchSemaphore(value: 0)
            Task { [writer] in
                try? await writer.append(
                    frame: frame,
                    monotonicNs: monotonicNs,
                    channels: channels,
                    deviceTimestampNs: deviceTimestampNs
                )
                semaphore.signal()
            }
            semaphore.wait()
            self.group.leave()
        }
    }

    func flush() {
        group.wait()
    }
}
