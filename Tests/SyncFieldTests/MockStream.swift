// Tests/SyncFieldTests/MockStream.swift
import Foundation
@testable import SyncField

enum TestError: Error { case boom }

actor MockStream: SyncFieldStream {
    // SyncFieldStream protocol requires these nonisolated
    nonisolated let streamId: String
    nonisolated let capabilities: StreamCapabilities
    let stopKind: String

    enum FailAt { case none, prepare, connect, start, stop, ingest, disconnect }
    var failAt: FailAt = .none
    var stopFailuresRemaining = 0

    var prepared = false
    var connected = false
    var recording = false
    var ingested  = false
    var stopCallCount = 0

    init(streamId: String, requiresIngest: Bool = false, kind: String = "sensor") {
        self.streamId = streamId
        self.capabilities = StreamCapabilities(
            requiresIngest: requiresIngest,
            producesFile: kind == "video")
        self.stopKind = kind
    }

    func setFailAt(_ f: FailAt) { self.failAt = f }
    func failNextStops(_ count: Int) { self.stopFailuresRemaining = count }

    func prepare() async throws {
        if failAt == .prepare { throw TestError.boom }
        prepared = true
    }

    func connect(context: StreamConnectContext) async throws {
        if failAt == .connect { throw TestError.boom }
        connected = true
    }

    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {
        if failAt == .start { throw TestError.boom }
        recording = true
    }

    func stopRecording() async throws -> StreamStopReport {
        stopCallCount += 1
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw TestError.boom
        }
        if failAt == .stop { throw TestError.boom }
        recording = false
        return StreamStopReport(streamId: streamId, frameCount: 0, kind: stopKind)
    }

    func ingest(into dir: URL, progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        if failAt == .ingest { throw TestError.boom }
        ingested = true
        return StreamIngestReport(streamId: streamId, filePath: nil, frameCount: 0)
    }

    func disconnect() async throws {
        if failAt == .disconnect { throw TestError.boom }
        connected = false
    }
}

/// A stream that owns a single connection but demuxes into more than one
/// manifest entry — simulates a future stereo camera stream that emits two
/// video streams (`cam_ego` + `cam_ego_wide`) from one `SyncFieldStream`.
struct MultiEntryFakeStream: SyncFieldStream {
    let streamId: String
    let capabilities: StreamCapabilities
    let entries: [Manifest.StreamEntry]

    init(streamId: String, entries: [Manifest.StreamEntry]) {
        self.streamId = streamId
        self.capabilities = StreamCapabilities(producesFile: true)
        self.entries = entries
    }

    func prepare() async throws {}
    func connect(context: StreamConnectContext) async throws {}
    func startRecording(clock: SessionClock, writerFactory: WriterFactory) async throws {}

    func stopRecording() async throws -> StreamStopReport {
        StreamStopReport(streamId: streamId, frameCount: 0, kind: "video")
    }

    func ingest(into episodeDirectory: URL,
                progress: @Sendable (Double) -> Void) async throws -> StreamIngestReport {
        StreamIngestReport(streamId: streamId, filePath: nil, frameCount: nil)
    }

    func disconnect() async throws {}

    func manifestEntries(report: StreamIngestReport?) -> [Manifest.StreamEntry] {
        entries
    }
}
