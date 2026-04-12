// Sources/SyncField/SessionOrchestrator.swift
import Foundation

public actor SessionOrchestrator {
    // MARK: Public API

    public init(hostId: String, outputDirectory: URL) {
        self.hostId = hostId
        self.baseDir = outputDirectory
    }

    public private(set) var state: SessionState = .idle
    public private(set) var episodeDirectory: URL = URL(fileURLWithPath: "/")

    public var healthEvents: AsyncStream<HealthEvent> { bus.subscribe() }

    public func add(_ stream: any SyncFieldStream) throws {
        guard state == .idle else {
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
        return anchor
    }

    public func stopRecording() async throws -> StopReport {
        try require(state: .recording, next: .stopping)
        var reports: [StreamStopReport] = []
        for s in streams {
            do { reports.append(try await s.stopRecording()) }
            catch { throw StreamError(streamId: s.streamId, underlying: error) }
        }
        if let writer = logWriter {
            try await writer.append(kind: "state", detail: "recording->stopping")
        }
        state = .stopping
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
