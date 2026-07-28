import Foundation

/// Lock-fronted writer pair shared by continuous sensor streams.
///
/// Producer callbacks enqueue while holding `lock`; commit swaps current and
/// prepared pairs under that same lock, then drains/closes the old pair after
/// releasing it. Every sample is therefore enqueued exactly once on one side
/// of the rotation even when a callback races the 30-minute boundary.
final class RotatingSensorWriter: @unchecked Sendable {
    private struct Slot {
        let writer: SensorWriter
        let pump: SensorWriterPump
        var count: Int
    }

    private let lock = NSLock()
    private let label: String
    private var current: Slot?
    private var prepared: Slot?

    init(label: String) {
        self.label = label
    }

    func start(writerFactory: WriterFactory, streamId: String) throws {
        let slot = try makeSlot(writerFactory: writerFactory, streamId: streamId)
        lock.lock()
        current = slot
        prepared = nil
        lock.unlock()
    }

    func prepare(writerFactory: WriterFactory, streamId: String) async throws {
        let slot = try makeSlot(writerFactory: writerFactory, streamId: streamId)
        if let stale = installPrepared(slot) {
            try? await Self.close(stale)
        }
    }

    func append(
        monotonicNs: UInt64,
        channels: [String: Any],
        deviceTimestampNs: UInt64? = nil
    ) {
        lock.lock()
        guard var slot = current else {
            lock.unlock()
            return
        }
        let frame = slot.count
        slot.count += 1
        current = slot
        slot.pump.append(
            writer: slot.writer,
            frame: frame,
            monotonicNs: monotonicNs,
            channels: channels,
            deviceTimestampNs: deviceTimestampNs
        )
        lock.unlock()
    }

    func commit() async throws -> Int {
        let old = try swapPreparedIntoCurrent()
        guard let old else { return 0 }
        try await Self.close(old)
        return old.count
    }

    func abortPrepared() async {
        let slot = takePrepared()
        if let slot { try? await Self.close(slot) }
    }

    func stop() async throws -> Int {
        let (old, staged) = takeAll()
        if let staged { try? await Self.close(staged) }
        guard let old else { return 0 }
        try await Self.close(old)
        return old.count
    }

    private func installPrepared(_ slot: Slot) -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        let stale = prepared
        prepared = slot
        return stale
    }

    private func swapPreparedIntoCurrent() throws -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = prepared else {
            throw NSError(
                domain: "SyncField.SegmentRotation", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "sensor rotation was not prepared"])
        }
        let old = current
        current = next
        prepared = nil
        return old
    }

    private func takePrepared() -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        let slot = prepared
        prepared = nil
        return slot
    }

    private func takeAll() -> (Slot?, Slot?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (current, prepared)
        current = nil
        prepared = nil
        return result
    }

    private func makeSlot(writerFactory: WriterFactory, streamId: String) throws -> Slot {
        Slot(
            writer: try writerFactory.makeSensorWriter(streamId: streamId),
            pump: SensorWriterPump(label: "\(label).\(UUID().uuidString)"),
            count: 0
        )
    }

    private static func close(_ slot: Slot) async throws {
        slot.pump.flush()
        try await slot.writer.close()
    }
}
