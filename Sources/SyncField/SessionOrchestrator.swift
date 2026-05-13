// Sources/SyncField/SessionOrchestrator.swift
import Foundation

private final class SessionStartTimeoutResumeGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: UnsafeContinuation<T, Error>,
        _ result: Result<T, Error>
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

public actor SessionOrchestrator {
    // MARK: Public API

    /// - Parameter preStopTailMarginMs: How long to keep recording AFTER the
    ///   stop chirp body finishes, in milliseconds. The orchestrator sleeps
    ///   for ``stopChirp.durationMs + preStopTailMarginMs`` between emitting
    ///   the chirp and broadcasting per-stream `stopRecording()`. The tail
    ///   has to absorb two distinct sources of slack so the chirp survives
    ///   on every host:
    ///
    ///   1. The downstream audio sync aligner cross-correlates a ±400 ms
    ///      window centred on the chirp peak. It needs roughly that much
    ///      *post-chirp* silence in every recording to find a confident peak.
    ///   2. Insta360 wrist cameras stop the underlying mp4 noticeably before
    ///      the BLE `stopCapture` round-trip completes — empirically 300–400
    ///      ms of trailing audio is dropped relative to the iPhone's own
    ///      AVAssetWriter end. Without an iPhone-side cushion that
    ///      compensates, the wrist cams' chirp body lands inside the last
    ///      few hundred ms of their recording with no usable post-chirp
    ///      silence (the cause of the ego_wrist sync failures observed in
    ///      production through 2026-05-12).
    ///
    ///   The default 800 ms covers both: 400 ms cross-correlation window
    ///   plus ~300–400 ms of Insta360 stop slack with safety. Pass a smaller
    ///   value if you only target hosts with negligible stop latency
    ///   (iPhone-only, or external mics that finalise immediately) and want
    ///   to shorten ``stopRecording()`` end-to-end latency. Pass ``0`` in
    ///   tests that mock the chirp player.
    public init(hostId: String,
                outputDirectory: URL,
                chirpPlayer: ChirpPlayer? = nil,
                startChirp: ChirpSpec? = .defaultStart,
                stopChirp: ChirpSpec? = .defaultStop,
                postStartStabilizationMs: Double = 200,
                preStopTailMarginMs: Double = 800,
                streamStartTimeoutSeconds: Double = 45,
                audioSessionPolicy: AudioSessionPolicy = .managedBySDK,
                handQualityConfig: HandQualityConfig = .default) {
        self.hostId = hostId
        self.baseDir = outputDirectory
        self.chirpPlayer = chirpPlayer ?? Self.defaultChirpPlayer()
        self.startChirpSpec = startChirp
        self.stopChirpSpec = stopChirp
        self.postStartStabilizationMs = postStartStabilizationMs
        self.preStopTailMarginMs = preStopTailMarginMs
        self.streamStartTimeoutSeconds = streamStartTimeoutSeconds
        self.audioSessionPolicy = audioSessionPolicy
        self.handQualityConfig = handQualityConfig
    }

    public private(set) var state: SessionState = .idle
    public private(set) var episodeDirectory: URL = URL(fileURLWithPath: "/")

    public var healthEvents: AsyncStream<HealthEvent> { bus.subscribe() }

    /// Register a stream with the session.
    ///
    /// Allowed in `.idle` (the usual pre-connect setup) and in `.connected`
    /// (a stream that was prepared externally — e.g. an `Insta360CameraStream`
    /// paired via `pairStandalone` by a host-app bridge before the user
    /// starts recording). Streams added post-connect do NOT have
    /// `connect(context:)` invoked by the orchestrator — the caller is
    /// responsible for ensuring the stream is already connected.
    public func add(_ stream: any SyncFieldStream) throws {
        guard state == .idle || state == .connected else {
            throw SessionError.invalidTransition(from: state, to: state)
        }
        if streams.contains(where: { $0.streamId == stream.streamId }) {
            throw SessionError.duplicateStreamId(stream.streamId)
        }
        streams.append(stream)
    }

    /// Deregister a stream from the session.
    ///
    /// Allowed in `.idle` (pre-connect cleanup) and `.connected` (host-driven
    /// remapping — e.g. unpairing a wrist Insta360 to pair a different camera
    /// under the same role/streamId). The caller owns the stream's own
    /// teardown — call `stream.disconnect()` separately if the stream is
    /// connected. The orchestrator merely drops its registration so a
    /// subsequent `add(_:)` with the same `streamId` no longer throws
    /// `duplicateStreamId`.
    ///
    /// Idempotent: returns `false` and leaves state untouched when no stream
    /// with `streamId` is registered. This matches the cleanup pattern host
    /// apps use during Remap (sweep every role, don't fight partial state).
    @discardableResult
    public func remove(streamId: String) throws -> Bool {
        guard state == .idle || state == .connected else {
            throw SessionError.invalidTransition(from: state, to: state)
        }
        let before = streams.count
        streams.removeAll { $0.streamId == streamId }
        return streams.count != before
    }

    /// streamIds currently registered with the session, in insertion order.
    /// Useful for diagnostics and for hosts that need to sweep their own
    /// bookkeeping against the orchestrator's view of registered streams.
    public func streamIds() -> [String] {
        streams.map { $0.streamId }
    }

    public func connect() async throws {
        try require(state: .idle, next: .connected)
        guard !streams.isEmpty else { throw SessionError.noStreamsRegistered }

        // Configure AVAudioSession FIRST so the chirp at startRecording emits
        // from the iPhone main speaker (not earpiece, not BT earbuds) and the
        // iPhone mic in `iPhoneCameraStream` can still record simultaneously.
        // Done before per-stream `connect(context:)` so AVCaptureSession's
        // audio path picks up the configured category from the start.
        applyAudioSessionPolicy()

        sessionId = String(UUID().uuidString.prefix(12).lowercased())
        var connected: [any SyncFieldStream] = []
        for s in streams {
            do {
                try await s.prepare()
                try await s.connect(context: StreamConnectContext(
                    sessionId: sessionId,
                    hostId: hostId,
                    healthBus: bus))
                connected.append(s)
            } catch {
                // Undo any already-connected streams
                for already in connected {
                    try? await already.disconnect()
                }
                state = .idle
                throw StreamError(streamId: s.streamId, underlying: error)
            }
        }
        state = .connected
    }

    /// Verify start-critical streams before the countdown begins.
    ///
    /// This keeps hardware failures out of the user-facing countdown path:
    /// host apps can call this when the user is ready to record, show a
    /// "connecting cameras" state, and only then call `startRecording`.
    public func preflightRecording() async throws {
        guard state == .connected else {
            throw SessionError.invalidTransition(from: state, to: .connected)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stream in streams {
                guard let preflight = stream as? any SyncFieldRecordingPreflightStream else {
                    continue
                }
                group.addTask { [stream, preflight] in
                    do {
                        try await preflight.preflightRecording()
                    } catch {
                        throw StreamError(streamId: stream.streamId, underlying: error)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @discardableResult
    public func startRecording(
        countdown: CountdownSpec? = nil,
        onTick: (@Sendable (Int) -> Void)? = nil
    ) async throws -> SyncPoint {
        try require(state: .connected, next: .recording)
        // Transition state IMMEDIATELY, before any `await`. Actor isolation
        // only holds between suspension points; a concurrent caller could
        // otherwise pass the same `require(state: .connected)` check while
        // we're still awaiting countdown / BLE start and end up running the
        // entire start sequence twice (double countdown, double chirp,
        // double BLE startCapture causing "msg execute err" on the second
        // send to each camera).
        state = .recording

        episodeDirectory = try makeEpisodeDirectory()
        let clock = SessionClock()
        let factory = WriterFactory(episodeDirectory: episodeDirectory)

        let anchor = clock.anchor(hostId: hostId)
        try writeSyncPoint(anchor)
        let writer = try SessionLogWriter(url: episodeDirectory.appendingPathComponent("session.log"))
        logWriter = writer
        try await writer.append(kind: "state", detail: "connected->recording")

        self.activeClock = clock

        // Hand FOV quality plumbing. The monitor and event writer live for the
        // duration of the recording; finalized in stopRecording().
        let evWriter = factory.makeEventWriter()
        self.eventWriter = evWriter
        self.recordingStartMonotonicNs = clock.nowMonotonicNs()
        self.handQualityMonitor = HandQualityMonitor(
            config: handQualityConfig,
            recordingStartMonotonicNs: recordingStartMonotonicNs,
            eventWriter: evWriter
        )

        // Atomic start: try all streams concurrently and wait for every host
        // to ACK before the audible/visible countdown starts. This avoids the
        // user-facing "stuck at 1" failure mode when an external camera is
        // slow or paired to a stale ActionPod endpoint: failures now surface
        // while the host app is still in its "starting cameras" state, before
        // the operator hears 3-2-1.
        var started: [String] = []
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                for s in streams {
                    let timeoutSeconds = streamStartTimeoutSeconds
                    group.addTask { [s] in
                        try await Self.withStartTimeout(
                            seconds: timeoutSeconds,
                            streamId: s.streamId
                        ) {
                            try await s.startRecording(clock: clock, writerFactory: factory)
                        }
                        return s.streamId
                    }
                }
                for try await id in group { started.append(id) }
            }
        } catch {
            // Roll back every stream, not only the ones that returned before
            // the failure. A timed-out SDK call can represent an ambiguous
            // start where the camera accepted capture but never delivered its
            // callback; best-effort stop keeps the rig safe for the next take.
            for s in streams {
                _ = try? await s.stopRecording()
            }
            try? FileManager.default.removeItem(at: episodeDirectory)
            state = .connected
            throw SessionError.startFailed(cause: error, rolledBack: started)
        }

        // State is already `.recording` (set at the top before any await
        // to gate concurrent callers).

        // Countdown after stream ACK: all hosts are already recording, so the
        // ticks and the start chirp are guaranteed to be present in every
        // audio track. Host apps should drive their visible countdown from the
        // `onTick` callback rather than from an independent JS timer.
        if let spec = countdown, spec.ticks > 0 {
            await runCountdown(spec, onTick: onTick)
        }

        // Chirp: wait for audio pipeline to stabilize, then emit
        if let spec = startChirpSpec {
            if postStartStabilizationMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(postStartStabilizationMs * 1_000_000))
            }
            self.startEmission = await chirpPlayer.play(spec)
        }

        // Update the on-disk sync_point.json with the chirp emission
        if let emission = startEmission {
            var sp = anchor
            sp.chirpStartNs = emission.bestNs
            sp.chirpStartSource = emission.source
            sp.chirpSpec = startChirpSpec
            try writeSyncPoint(sp)
            self.currentSyncPoint = sp
        } else {
            self.currentSyncPoint = anchor
        }

        return anchor
    }

    public func stopRecording() async throws -> StopReport {
        let isRetryingStop: Bool
        switch state {
        case .recording:
            // Transition state IMMEDIATELY, before any `await`. Without this the
            // chirp emit + tail margin sleep (~700ms) opens a window where a
            // concurrent caller could re-enter and pass the same require check.
            state = .stopping
            stopReportsByStreamId.removeAll()
            isRetryingStop = false
        case .stopping:
            // Previous stop attempt confirmed some streams and failed others.
            // Retry only streams that do not yet have a stop report.
            isRetryingStop = true
        default:
            throw SessionError.invalidTransition(from: state, to: .stopping)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds

        // Stop chirp: emit first, wait for tail to be captured
        if !isRetryingStop, let spec = stopChirpSpec {
            self.stopEmission = await chirpPlayer.play(spec)
            let waitMs = spec.durationMs + preStopTailMarginMs
            try? await Task.sleep(nanoseconds: UInt64(waitMs * 1_000_000))

            // Update sync_point.json with stop chirp
            if var sp = currentSyncPoint, let em = stopEmission {
                sp.chirpStopNs = em.bestNs
                sp.chirpStopSource = em.source
                try writeSyncPoint(sp)
                self.currentSyncPoint = sp
            }
        }
        let tAfterChirp = DispatchTime.now().uptimeNanoseconds
        NSLog("[SDK.stopRecording] chirp+tail done elapsedMs=\((tAfterChirp - t0) / 1_000_000)")

        // Run each stream's stopRecording concurrently. Rationale:
        // - iPhoneCameraStream / iPhoneMotionStream / TactileStream are
        //   independent of each other, sequential or parallel is fine.
        // - Insta360CameraStream issues BLE `stopCapture` per device; the
        //   underlying Insta360 SDK maintains per-camera state, and
        //   back-to-back serial calls on sibling cameras have been
        //   observed to fail the second with "msg execute err" in the
        //   field. Firing them in parallel sidesteps that and matches the
        //   v0.1 `stopCaptureAll` pattern that worked in production.
        //
        // Errors are collected rather than short-circuited so that a
        // failing BLE camera doesn't cancel a healthy stream's finalise
        // (AVAssetWriter commit etc).
        var firstError: Error?
        let tBeforeStreamStop = DispatchTime.now().uptimeNanoseconds
        await withTaskGroup(of: (StreamStopReport?, Error?).self) { group in
            for s in streams {
                if stopReportsByStreamId[s.streamId] != nil { continue }
                let id = s.streamId
                group.addTask { [s] in
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let result: (StreamStopReport?, Error?)
                    do { result = (try await s.stopRecording(), nil) }
                    catch {
                        result = (nil, StreamError(streamId: s.streamId, underlying: error))
                    }
                    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                    NSLog("[SDK.stopRecording] stream=\(id) stop elapsedMs=\(elapsedMs)")
                    return result
                }
            }
            for await (report, error) in group {
                if let report = report {
                    stopReportsByStreamId[report.streamId] = report
                }
                if let error = error, firstError == nil { firstError = error }
            }
        }
        let tAfterStreamStop = DispatchTime.now().uptimeNanoseconds
        NSLog("[SDK.stopRecording] all streams stopped elapsedMs=\((tAfterStreamStop - tBeforeStreamStop) / 1_000_000)")

        if let writer = logWriter {
            try await writer.append(kind: "state", detail: "recording->stopping")
        }

        // Finalize hand FOV quality: capture stats, close any open intervals,
        // write hand_quality.json. Failures here are non-fatal (a recording
        // without quality metadata is still a valid recording).
        let tBeforeHQ = DispatchTime.now().uptimeNanoseconds
        if let monitor = handQualityMonitor {
            let stopNs = activeClock?.nowMonotonicNs() ?? recordingStartMonotonicNs
            let stats = await monitor.qualityStats(
                recordingStartMonotonicNs: recordingStartMonotonicNs,
                stopMonotonicNs: stopNs
            )
            self.lastHandQualityStats = stats
            await monitor.finalize(stopMonotonicNs: stopNs, stopFrame: -1)
            let summary = HandQualitySummaryBuilder.build(stats: stats, config: handQualityConfig)
            let summaryURL = episodeDirectory.appendingPathComponent("hand_quality.json")
            try? HandQualitySummaryBuilder.write(summary, to: summaryURL)
        }
        let tAfterHQ = DispatchTime.now().uptimeNanoseconds
        NSLog("[SDK.stopRecording] hand quality finalize elapsedMs=\((tAfterHQ - tBeforeHQ) / 1_000_000)")
        // EventWriter is finalized as part of monitor.finalize; drop the reference
        // so future logEvent calls become no-ops until the next startRecording.
        eventWriter = nil
        handQualityMonitor = nil

        // Write manifest.json at stop time (not only at ingest time).
        // Host apps that skip the orchestrator's `ingest()` phase — e.g.
        // egonaut's Phase-C "pull wrist videos later" flow — would
        // otherwise end up with an episode directory missing the
        // manifest that downstream sync pipelines require. Each entry
        // is derived from the stream-stop report when the stream has
        // already closed its file, falling back to the conventional
        // `<streamId>.jsonl` path for sensor streams.
        let manifestResults: [String: Result<StreamIngestReport, Error>] =
            Dictionary(uniqueKeysWithValues: stopReportsInStreamOrder().map { r in
                (r.streamId, .success(StreamIngestReport(
                    streamId: r.streamId,
                    filePath: Self.defaultFilePath(streamId: r.streamId, kind: r.kind),
                    frameCount: r.frameCount)))
            })
        try? writeManifest(from: manifestResults)

        // State is already `.stopping` (set at the top before any await
        // to gate concurrent callers).
        if let error = firstError { throw error }
        return StopReport(streamReports: stopReportsInStreamOrder())
    }

    /// Close the recording without running per-stream `ingest`. Use this when
    /// you intend to collect Insta360 wrist mp4s later via
    /// ``SyncFieldInsta360/Insta360Collector`` — single-episode or batched.
    ///
    /// On return, `state == .connected`. The episode directory already
    /// contains every native-stream file (camera mp4 + timestamps, sensor
    /// jsonl), `manifest.json`, and `sync_point.json`. For each Insta360
    /// stream, a `<streamId>.pending.json` sidecar records the camera-side
    /// file URI and BLE-ACK monotonic anchor needed for later download.
    ///
    /// Call `disconnect()` after this just like you would after `ingest()`.
    public func finishRecording() async throws {
        try require(state: .stopping, next: .connected)
        // Transition state before the log-writer awaits so a concurrent
        // call can't pass the same `require(state: .stopping)` check.
        state = .connected
        if let writer = logWriter {
            try await writer.append(kind: "state", detail: "stopping->connected (deferred ingest)")
            try await writer.close()
        }
        logWriter = nil
    }

    public func ingest(progress: @Sendable (IngestProgress) -> Void) async throws -> IngestReport {
        try require(state: .stopping, next: .ingesting)
        state = .ingesting

        var results: [String: Result<StreamIngestReport, Error>] = [:]
        for s in streams {
            let id = s.streamId
            do {
                let report = try await s.ingest(into: episodeDirectory) { fraction in
                    progress(IngestProgress(streamId: id, fraction: fraction))
                }
                results[id] = .success(report)
            } catch {
                await bus.publish(.ingestFailed(streamId: id, error: error))
                results[id] = .failure(error)
            }
        }

        try writeManifest(from: results)
        if let writer = logWriter {
            try await writer.append(kind: "state", detail: "ingesting->connected")
            try await writer.close()
        }
        logWriter = nil

        state = .connected
        return IngestReport(streamResults: results)
    }

    public func disconnect() async throws {
        try require(state: .connected, next: .idle)
        for s in streams {
            try? await s.disconnect()
        }
        bus.finish()
        state = .idle
    }

    // MARK: Private

    private let hostId: String
    private let baseDir: URL
    private var streams: [any SyncFieldStream] = []
    private var sessionId: String = ""
    private var activeClock: SessionClock?
    private var logWriter: SessionLogWriter?
    private let bus = HealthBus()

    // Chirp state
    private let chirpPlayer: ChirpPlayer
    private let startChirpSpec: ChirpSpec?
    private let stopChirpSpec: ChirpSpec?
    private let postStartStabilizationMs: Double
    private let preStopTailMarginMs: Double
    private let streamStartTimeoutSeconds: Double
    private let audioSessionPolicy: AudioSessionPolicy
    private let countdownTickPlayer = CountdownTickPlayer()
    private var startEmission: ChirpEmission?
    private var stopEmission: ChirpEmission?
    private var currentSyncPoint: SyncPoint?
    private var stopReportsByStreamId: [String: StreamStopReport] = [:]

    // Hand FOV quality state — created in startRecording, finalized in stopRecording.
    private var handQualityConfig: HandQualityConfig
    private var handQualityMonitor: HandQualityMonitor?
    private var eventWriter: EventWriter?
    private var recordingStartMonotonicNs: UInt64 = 0
    private var lastHandQualityStats: QualityStats?

    private static func defaultChirpPlayer() -> ChirpPlayer {
        #if canImport(AVFoundation) && os(iOS)
        return AVAudioEngineChirpPlayer()
        #else
        return SilentChirpPlayer()
        #endif
    }

    private static func withStartTimeout<T: Sendable>(
        seconds: Double,
        streamId: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let operationTask = Task<T, Error> {
            try await operation()
        }
        let gate = SessionStartTimeoutResumeGate<T>()
        var timeoutTask: Task<Void, Never>?
        defer {
            operationTask.cancel()
            timeoutTask?.cancel()
        }

        return try await withUnsafeThrowingContinuation { continuation in
            timeoutTask = Task.detached {
                let ns = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                let error = NSError(
                    domain: "SyncField.SessionOrchestrator",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "stream \(streamId) start timed out after \(seconds)s"])
                gate.resume(continuation, .failure(error))
            }

            Task.detached {
                do {
                    gate.resume(continuation, .success(try await operationTask.value))
                } catch {
                    gate.resume(continuation, .failure(error))
                }
            }
        }
    }

    private func stopReportsInStreamOrder() -> [StreamStopReport] {
        streams.compactMap { stopReportsByStreamId[$0.streamId] }
    }

    /// Run the pre-start countdown. For each tick: fire `onTick(remaining)`
    /// so the host UI can flash the number, optionally play an ascending
    /// tone on the iPhone main speaker, then sleep `intervalMs` before
    /// the next tick. Cancellable through the surrounding Task.
    private func runCountdown(
        _ spec: CountdownSpec,
        onTick: (@Sendable (Int) -> Void)?
    ) async {
        let player = countdownTickPlayer
        for i in 0..<spec.ticks {
            let remaining = spec.ticks - i
            onTick?(remaining)
            if spec.style == .audible {
                player.play(tickIndex: i)
            }
            if i < spec.ticks - 1 {
                try? await Task.sleep(
                    nanoseconds: UInt64(spec.intervalMs * 1_000_000))
            } else {
                // Hold the last tick for its own duration before kicking
                // off BLE start so the operator's perceived rhythm
                // doesn't skip "1 -> CHIRP" with no breathing room.
                try? await Task.sleep(
                    nanoseconds: UInt64(spec.intervalMs * 1_000_000))
            }
        }
    }

    /// Apply the active `AudioSessionPolicy`. On `.managedBySDK`, set the
    /// shared `AVAudioSession` to play-and-record + speaker-routed so the
    /// chirp is audible to every nearby microphone. Failures are logged
    /// but non-fatal (a misconfigured session typically still records,
    /// just with a quieter chirp; the BLE-ACK anchor in
    /// `<streamId>.anchor.json` still gives sync alignment within ~50 ms).
    private func applyAudioSessionPolicy() {
        guard audioSessionPolicy == .managedBySDK else { return }
        #if canImport(AVFoundation) && os(iOS)
        do {
            try SyncFieldAudioSession.applyManagedConfig()
        } catch {
            NSLog("[SyncField] AVAudioSession config failed (\(error.localizedDescription)); continuing with whatever the host left in place.")
        }
        #endif
    }

    private func require(state expected: SessionState, next: SessionState) throws {
        let allowed: [(from: SessionState, to: SessionState)] = [
            (.idle,       .connected),
            (.connected,  .recording),
            (.recording,  .stopping),
            (.stopping,   .ingesting),
            (.stopping,   .connected),   // finishRecording — skip ingest, collect later
            (.ingesting,  .connected),
            (.connected,  .idle),
        ]
        guard state == expected,
              allowed.contains(where: { $0.from == expected && $0.to == next }) else {
            throw SessionError.invalidTransition(from: state, to: next)
        }
    }

    private func makeEpisodeDirectory() throws -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.timeZone = TimeZone(identifier: "UTC")
        let stamp = df.string(from: Date())
        let short = String(UUID().uuidString.prefix(6).lowercased())
        let dir = baseDir.appendingPathComponent("ep_\(stamp)_\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSyncPoint(_ sp: SyncPoint) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(sp).write(
            to: episodeDirectory.appendingPathComponent("sync_point.json"),
            options: [.atomic])
    }

    private func writeManifest(
        from results: [String: Result<StreamIngestReport, Error>]) throws {
        let entries: [Manifest.StreamEntry] = streams.map { s in
            let report = (try? results[s.streamId]?.get()) ?? nil
            return Manifest.StreamEntry(
                streamId: s.streamId,
                filePath: report?.filePath ?? Self.defaultFilePath(
                    streamId: s.streamId,
                    kind: s.capabilities.producesFile ? "video" : "sensor"),
                frameCount: report?.frameCount ?? 0,
                kind: s.capabilities.producesFile ? "video" : "sensor",
                capabilities: s.capabilities)
        }
        let manifest = Manifest(
            sdkVersion: SyncFieldVersion.current,
            hostId: hostId,
            role: "single",
            streams: entries)
        try ManifestWriter.write(
            manifest,
            to: episodeDirectory.appendingPathComponent("manifest.json"))
    }

    private static func defaultFilePath(streamId: String, kind: String) -> String {
        kind == "video" ? "\(streamId).mp4" : "\(streamId).jsonl"
    }
}

// MARK: - Hand FOV quality public API

extension SessionOrchestrator {
    /// Update the hand-quality config. Takes effect on the next call to
    /// ``startRecording(countdown:)``; live recordings keep the config they
    /// were started with.
    public func setHandQualityConfig(_ config: HandQualityConfig) {
        self.handQualityConfig = config
    }

    /// Stream of per-hand state-machine transitions. Call after
    /// ``startRecording(countdown:)`` returns; before that, the monitor
    /// does not exist and the returned stream completes immediately.
    public func handQualityEvents() -> AsyncStream<HandQualityEvent> {
        guard let monitor = handQualityMonitor else {
            return AsyncStream { $0.finish() }
        }
        return monitor.events
    }

    /// Feed one frame's worth of detected hands into the quality monitor.
    /// Host apps that do their own Vision detection (the egonaut RN bridge)
    /// call this after each frame's `VNDetectHumanHandPoseRequest` completes.
    /// Safe to call before/after a recording — silently no-ops if the
    /// monitor is not active.
    public func ingestHandObservations(_ observations: [HandObservation],
                                       frame: Int,
                                       monotonicNs: UInt64) async {
        await handQualityMonitor?.ingest(observations: observations,
                                         frame: frame,
                                         monotonicNs: monotonicNs)
    }

    /// Append an arbitrary domain event to the per-episode `events.jsonl`.
    /// Pass `endMonotonicNs == nil` (or equal to `monotonicNs`) for a point
    /// event; otherwise an interval is emitted in one shot.
    public func logEvent(kind: String,
                         monotonicNs: UInt64,
                         endMonotonicNs: UInt64?,
                         payload: [String: Any]) async throws {
        guard let writer = eventWriter else { return }
        if let endNs = endMonotonicNs, endNs != monotonicNs {
            let h = try await writer.appendIntervalStart(
                kind: kind,
                startMonotonicNs: monotonicNs,
                startFrame: -1,
                payload: payload
            )
            try await writer.closeInterval(handle: h, endMonotonicNs: endNs, endFrame: -1)
        } else {
            try await writer.appendPoint(kind: kind, monotonicNs: monotonicNs, payload: payload)
        }
        await writer.flush()
    }
}

public struct StopReport: Sendable {
    public let streamReports: [StreamStopReport]
}

public struct IngestProgress: Sendable {
    public let streamId: String
    public let fraction: Double
}

public struct IngestReport: Sendable {
    public let streamResults: [String: Result<StreamIngestReport, Error>]
}
