// Sources/SyncField/SessionOrchestrator.swift
import Foundation

public actor SessionOrchestrator {
    // MARK: Public API

    public init(hostId: String,
                outputDirectory: URL,
                chirpPlayer: ChirpPlayer? = nil,
                startChirp: ChirpSpec? = .defaultStart,
                stopChirp: ChirpSpec? = .defaultStop,
                postStartStabilizationMs: Double = 200,
                preStopTailMarginMs: Double = 200) {
        self.hostId = hostId
        self.baseDir = outputDirectory
        self.chirpPlayer = chirpPlayer ?? Self.defaultChirpPlayer()
        self.startChirpSpec = startChirp
        self.stopChirpSpec = stopChirp
        self.postStartStabilizationMs = postStartStabilizationMs
        self.preStopTailMarginMs = preStopTailMarginMs
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

    public func connect() async throws {
        try require(state: .idle, next: .connected)
        guard !streams.isEmpty else { throw SessionError.noStreamsRegistered }

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

    @discardableResult
    public func startRecording(countdown: TimeInterval = 0) async throws -> SyncPoint {
        try require(state: .connected, next: .recording)

        episodeDirectory = try makeEpisodeDirectory()
        let clock = SessionClock()
        let factory = WriterFactory(episodeDirectory: episodeDirectory)

        let anchor = clock.anchor(hostId: hostId)
        try writeSyncPoint(anchor)
        let writer = try SessionLogWriter(url: episodeDirectory.appendingPathComponent("session.log"))
        logWriter = writer
        try await writer.append(kind: "state", detail: "connected->recording")

        self.activeClock = clock

        if countdown > 0 {
            try await Task.sleep(nanoseconds: UInt64(countdown * 1_000_000_000))
        }

        // Atomic start: try all concurrently; roll back any that succeeded if any fails.
        var started: [String] = []
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                for s in streams {
                    group.addTask { [s] in
                        try await s.startRecording(clock: clock, writerFactory: factory)
                        return s.streamId
                    }
                }
                for try await id in group { started.append(id) }
            }
        } catch {
            // Roll back: stop the ones that started, delete their files.
            for s in streams where started.contains(s.streamId) {
                _ = try? await s.stopRecording()
            }
            try? FileManager.default.removeItem(at: episodeDirectory)
            state = .connected
            throw SessionError.startFailed(cause: error, rolledBack: started)
        }

        state = .recording

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
        try require(state: .recording, next: .stopping)

        // Stop chirp: emit first, wait for tail to be captured
        if let spec = stopChirpSpec {
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
        var reports: [StreamStopReport] = []
        var firstError: Error?
        await withTaskGroup(of: (StreamStopReport?, Error?).self) { group in
            for s in streams {
                group.addTask { [s] in
                    do { return (try await s.stopRecording(), nil) }
                    catch {
                        return (nil, StreamError(streamId: s.streamId, underlying: error))
                    }
                }
            }
            for await (report, error) in group {
                if let report = report { reports.append(report) }
                if let error = error, firstError == nil { firstError = error }
            }
        }
        if let writer = logWriter {
            try await writer.append(kind: "state", detail: "recording->stopping")
        }
        state = .stopping
        if let error = firstError { throw error }
        return StopReport(streamReports: reports)
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
    private var startEmission: ChirpEmission?
    private var stopEmission: ChirpEmission?
    private var currentSyncPoint: SyncPoint?

    private static func defaultChirpPlayer() -> ChirpPlayer {
        #if canImport(AVFoundation) && os(iOS)
        return AVAudioEngineChirpPlayer()
        #else
        return SilentChirpPlayer()
        #endif
    }

    private func require(state expected: SessionState, next: SessionState) throws {
        let allowed: [(from: SessionState, to: SessionState)] = [
            (.idle,       .connected),
            (.connected,  .recording),
            (.recording,  .stopping),
            (.stopping,   .ingesting),
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
                filePath: report?.filePath ?? "\(s.streamId).jsonl",
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
