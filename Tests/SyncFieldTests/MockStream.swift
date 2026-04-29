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

    var prepared = false
    var connected = false
    var recording = false
    var ingested  = false

    init(streamId: String, requiresIngest: Bool = false, kind: String = "sensor") {
        self.streamId = streamId
        self.capabilities = StreamCapabilities(
            requiresIngest: requiresIngest,
            producesFile: kind == "video")
        self.stopKind = kind
    }

    func setFailAt(_ f: FailAt) { self.failAt = f }

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
