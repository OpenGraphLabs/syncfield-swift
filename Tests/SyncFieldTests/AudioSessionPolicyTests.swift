// Tests/SyncFieldTests/AudioSessionPolicyTests.swift
import XCTest
@testable import SyncField

#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

final class AudioSessionPolicyTests: XCTestCase {
    func test_default_policy_is_managedBySDK() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-audio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Smoke: orchestrator init with no audioSessionPolicy arg must
        // compile and behave like the explicit managed value. We can't
        // observe AVAudioSession state on macOS, so this test pins the
        // contract at the API surface.
        let s = SessionOrchestrator(hostId: "h", outputDirectory: dir)
        let state = await s.state
        XCTAssertEqual(state, .idle, "default init should land in .idle just like before")
    }

    func test_manual_policy_init_compiles() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-audio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pinning the public API for hosts that own AVAudioSession themselves.
        let s = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            audioSessionPolicy: .manualByHost)
        let state = await s.state
        XCTAssertEqual(state, .idle)
    }

    #if canImport(AVFoundation) && os(iOS)
    func test_managed_policy_applies_speakerRouted_category_on_iOS() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            audioSessionPolicy: .managedBySDK)
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .videoRecording)
        // `.defaultToSpeaker` is the critical flag, without it the chirp
        // routes to the iPhone earpiece and surrounding Insta360 mics
        // can't pick it up.
        XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        // BT routing is intentionally NOT in the options on iOS, see
        // SyncFieldAudioSession docs for why.
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetooth))
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetoothA2DP))
    }

    func test_manual_policy_does_not_touch_audio_session_on_iOS() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sft-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-set a category the SDK would never choose.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, options: [])

        let s = SessionOrchestrator(
            hostId: "h",
            outputDirectory: dir,
            audioSessionPolicy: .manualByHost)
        try await s.add(MockStream(streamId: "a"))
        try await s.connect()

        XCTAssertEqual(session.category, .ambient,
                       "manualByHost must leave host-managed category alone")
    }

    func test_applyManagedConfig_is_idempotent() throws {
        // Calling twice in a row must not throw and must leave the same
        // configured state — needed because both SessionOrchestrator and
        // AVAudioEngineChirpPlayer can apply it in the same run.
        try SyncFieldAudioSession.applyManagedConfig()
        try SyncFieldAudioSession.applyManagedConfig()
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord)
    }
    #endif
}
