// Sources/SyncField/Streams/Tactile/TactileStream.swift
import Foundation

/// Live sample emitted by `TactileStream.setSampleHandler` — lets host apps
/// subscribe to real-time sensor values for UI preview, gesture recognition,
/// or custom triggers without touching the on-disk JSONL.
///
/// The handler fires on the BLE delivery queue, not the main queue; dispatch
/// to the main thread yourself if the handler updates UI.
public struct TactileSampleEvent: Sendable {
    public let streamId: String
    public let side: TactileSide
    public let frame: Int
    /// Host monotonic nanoseconds (same domain as `SessionClock.nowMonotonicNs()`).
    public let monotonicNs: UInt64
    /// Firmware hardware clock in nanoseconds (`t_base_us + dt_us`).
    public let deviceTimestampNs: UInt64
    /// Channel label → raw 12-bit taxel value (0–4095). Labels are `<finger>_<row>_<col>`
    /// from the firmware manifest finger order and `sample_shape` (e.g. `thumb_0_1`).
    public let channels: [String: Int]
}

public final class TactileStream: SyncFieldStream, @unchecked Sendable {
    public nonisolated let streamId: String
    public nonisolated let capabilities = StreamCapabilities(
        requiresIngest: false, producesFile: false,
        supportsPreciseTimestamps: true, providesAudioTrack: false)

    /// Which glove side this stream is configured for.
    public let side: TactileSide

    private let client = TactileBLEClient()

    /// Optional sibling stream that receives this glove's wrist IMU. Set by the bridge
    /// so the per-sample raw 6-axis IMU lands in its own `wrist_imu_<side>.jsonl` with
    /// the SAME timestamps as the tactile rows. nil → IMU is omitted.
    public weak var wristImuSibling: WristImuStream?

    private var writer: SensorWriter?
    private var clock: SessionClock?
    private var healthBus: HealthBus?
    private var manifest: DeviceManifest?
    private var frameCount = 0
    private var isSubscribed = false

    // Notify-loss detection (firmware base-timestamp gap tracking).
    private var lastBatchTsUs: UInt32?
    private var lastBatchCount: Int = 0

    private let handlerLock = NSLock()
    private var _sampleHandler: (@Sendable (TactileSampleEvent) -> Void)?

    /// Background glove-acquisition loop. Tactile gloves are OPTIONAL, so connect()
    /// must never block or fail the session (SessionOrchestrator.connect() runs
    /// stream connects serially and tears the whole session down if any throws).
    private var acquireTask: Task<Void, Never>?

    public init(streamId: String, side: TactileSide) {
        self.streamId = streamId
        self.side = side
    }

    /// Attach (or detach with `nil`) a live sample handler. Safe to call at any
    /// point in the session — connect-time, recording-time, or after stop.
    /// Passing `nil` removes any previously installed handler.
    public func setSampleHandler(_ handler: (@Sendable (TactileSampleEvent) -> Void)?) {
        handlerLock.lock(); defer { handlerLock.unlock() }
        _sampleHandler = handler
    }

    public func prepare() async throws {}

    /// Re-publish the current connection state to HealthBus. Call when the UI
    /// re-mounts (screen navigation) so the row reflects reality (green/red)
    /// instead of a stale "unknown" state. Reconnects if the link dropped.
    public func refreshState() {
        client.reemitState()
    }

    public func connect(context: StreamConnectContext) async throws {
        self.healthBus = context.healthBus
        self.lastBatchTsUs = nil
        self.lastBatchCount = 0
        // Best-effort, NON-BLOCKING: gloves are optional, so we must return
        // immediately and acquire in the background. Otherwise a missing/flaky
        // glove (weak RSSI, powered off, busy) blocks SessionOrchestrator.connect()
        // and — because that runs serially and rethrows — freezes/fails the whole
        // setup. The UI reflects connect/disconnect via HealthBus; data flows
        // once/if the glove connects.
        acquireTask?.cancel()
        acquireTask = Task { [weak self] in
            await self?.runAcquireLoop()
        }
    }

    /// Background acquisition: scan → connect → verify side → claim, retrying
    /// indefinitely (with backoff) until connected or disconnect() cancels us.
    ///
    /// Exclusion policy is the crux of robustness on a flaky link:
    ///  - `wrongSide` → this is the OTHER glove; exclude it and keep scanning.
    ///  - claim lost  → another stream owns it; exclude and keep scanning.
    ///  - any other error (connect/config-read failure, common at weak RSSI) →
    ///    do NOT exclude; back off and retry the SAME glove. (The earlier bug
    ///    excluded on transient errors, permanently dropping the only glove.)
    private func runAcquireLoop() async {
        var excluded: Set<UUID> = []
        while !Task.isCancelled {
            do {
                let claimedElsewhere = await TactileRoleRegistry.shared.claimedIds()
                let exclude = excluded.union(
                    Set(claimedElsewhere.compactMap { UUID(uuidString: $0) }))
                let ref = try await client.scan(timeoutSeconds: 12, excluding: exclude)
                if Task.isCancelled { client.disconnect(); return }
                do {
                    let m = try await client.connectAndPrepare(ref, expectedSide: side)
                    let claimed = await TactileRoleRegistry.shared
                        .tryClaim(ref.identifier.uuidString, side: side)
                    guard claimed else {
                        excluded.insert(ref.identifier)
                        client.disconnect()
                        continue
                    }
                    if Task.isCancelled { client.disconnect(); return }
                    // Connected + claimed.
                    self.manifest = m
                    self.isSubscribed = true
                    try client.subscribe { [weak self] data, arrivalNs in
                        self?.handlePacket(data, arrivalNs: arrivalNs)
                    }
                    client.enableAutoReconnect { [weak self] connected, reason in
                        guard let self else { return }
                        let sid = self.streamId
                        Task { [weak self] in
                            if connected {
                                await self?.healthBus?.publish(.streamConnected(streamId: sid))
                            } else {
                                await self?.healthBus?.publish(
                                    .streamDisconnected(streamId: sid, reason: reason))
                            }
                        }
                    }
                    await healthBus?.publish(.streamConnected(streamId: streamId))
                    return  // success; auto-reconnect handles future drops
                } catch TactileBLEClient.Error.wrongSide {
                    excluded.insert(ref.identifier)   // definitively the other side
                    client.disconnect()
                } catch {
                    client.disconnect()               // transient — retry same glove
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            } catch {
                // scan timeout / BT not ready → brief backoff, keep trying.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    public func startRecording(clock: SessionClock,
                               writerFactory: WriterFactory) async throws {
        self.clock = clock
        self.writer = try writerFactory.makeSensorWriter(streamId: streamId)
        self.frameCount = 0
    }

    public func stopRecording() async throws -> StreamStopReport {
        let final = frameCount
        try await writer?.close()
        writer = nil
        return StreamStopReport(streamId: streamId, frameCount: final, kind: "sensor")
    }

    public func ingest(into dir: URL,
                       progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId,
                           filePath: "\(streamId).jsonl",
                           frameCount: frameCount)
    }

    public func disconnect() async throws {
        isSubscribed = false
        acquireTask?.cancel()
        acquireTask = nil
        setSampleHandler(nil)
        client.disconnect()
        await TactileRoleRegistry.shared.release(side: side)
        await healthBus?.publish(.streamDisconnected(streamId: streamId, reason: "normal"))
    }

    private func handlePacket(_ data: Data, arrivalNs: UInt64) {
        guard isSubscribed, let manifest = manifest else { return }

        handlerLock.lock()
        let handler = _sampleHandler
        handlerLock.unlock()

        let vps = manifest.valuesPerSample ?? TactileConstants.defaultValuesPerSample
        guard let packet = try? TactilePacketParser.parseV5(data, valuesPerSample: vps) else { return }

        let rateHz = manifest.rateHz > 0 ? manifest.rateHz : 100
        let intervalUs = UInt64(1_000_000 / rateHz)
        detectLoss(batchTsUs: packet.tBaseUs, count: packet.count, intervalUs: intervalUs)

        let shape = manifest.sampleShape ?? [5, 4, 4]
        let rows = shape.count > 1 ? shape[1] : 4
        let cols = shape.count > 2 ? shape[2] : 4
        let perFinger = max(rows * cols, 1)

        for (i, taxels) in packet.samples.enumerated() {
            let frame = frameCount
            frameCount += 1

            // Real per-sample timestamps from the firmware clock (t_base_us + dt_us),
            // not a synthesised cadence. captureNs uses the same dt for true intra-batch
            // spacing relative to packet arrival.
            let dtNs = UInt64(packet.dtUs[i]) &* 1_000
            let captureNs = arrivalNs &+ dtNs
            let deviceTsNs = (UInt64(packet.tBaseUs) &+ UInt64(packet.dtUs[i])) &* 1_000

            // Taxels → tactile stream (preview + tactile_<side>.jsonl).
            var channelsOut: [String: Int] = [:]
            channelsOut.reserveCapacity(taxels.count)
            for (t, raw) in taxels.enumerated() {
                let f = t / perFinger
                let rem = t % perFinger
                let r = cols > 0 ? rem / cols : 0
                let c = cols > 0 ? rem % cols : 0
                let finger = (f < manifest.fingerLabels.count) ? manifest.fingerLabels[f] : "f\(f)"
                channelsOut["\(finger)_\(r)_\(c)"] = Int(raw)
            }
            emit(frame: frame, captureNs: captureNs, deviceTsNs: deviceTsNs,
                 channels: channelsOut, handler: handler)

            // Per-sample raw 6-axis IMU → separate wrist_imu_<side>.jsonl (same
            // timestamps), kept as its own modality. Dropped if no sibling is linked
            // or the IMU block was truncated.
            if let imu = packet.imu[i], let sibling = wristImuSibling {
                sibling.append(captureNs: captureNs, deviceTimestampNs: deviceTsNs,
                               channels: rawImuChannels(imu))
            }
        }
    }

    /// Fire the live handler (always) and persist to JSONL (only while recording).
    private func emit(frame: Int, captureNs: UInt64, deviceTsNs: UInt64,
                      channels: [String: Int],
                      handler: (@Sendable (TactileSampleEvent) -> Void)?) {
        if let handler = handler {
            handler(TactileSampleEvent(
                streamId: streamId, side: side, frame: frame,
                monotonicNs: captureNs, deviceTimestampNs: deviceTsNs, channels: channels))
        }
        if let writer = writer {
            let channelsAny: [String: Any] = channels.mapValues { $0 as Any }
            Task {
                try? await writer.append(frame: frame, monotonicNs: captureNs,
                                         channels: channelsAny, deviceTimestampNs: deviceTsNs)
            }
        }
    }

    /// Wrist-IMU JSONL channel layout: raw 6-axis only (schema_ver 5). The firmware
    /// no longer computes on-device roll/pitch fusion, so those columns are gone.
    private func rawImuChannels(_ imu: TactileRawImuSample) -> [String: Int] {
        [
            "ax": Int(imu.ax), "ay": Int(imu.ay), "az": Int(imu.az),
            "gx": Int(imu.gx), "gy": Int(imu.gy), "gz": Int(imu.gz),
        ]
    }

    /// Detect dropped notifies via firmware base-timestamp gaps and surface them as
    /// `HealthEvent.samplesDropped` (reusing an existing case — no enum changes).
    /// Runs only on the serial BLE notify queue, so the gap state needs no lock.
    private func detectLoss(batchTsUs: UInt32, count: Int, intervalUs: UInt64) {
        defer { lastBatchTsUs = batchTsUs; lastBatchCount = count }
        guard let prev = lastBatchTsUs, lastBatchCount > 0, intervalUs > 0 else { return }
        let delta = UInt64(batchTsUs &- prev)              // wraps correctly in the u32 domain
        let expected = UInt64(lastBatchCount) &* intervalUs
        guard delta > expected &+ (intervalUs &* 3 / 2) else { return }  // tolerate ~1.5 sample jitter
        let missed = Int((delta &- expected) / intervalUs)
        guard missed > 0, missed < 10_000 else { return }  // ignore absurd gaps (long downtime)
        let sid = streamId
        Task { [weak self] in
            await self?.healthBus?.publish(.samplesDropped(streamId: sid, count: missed))
        }
    }
}
