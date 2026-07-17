// Tests/SyncFieldTests/MultiCamCameraStreamTests.swift
//
// Pure (device-free) coverage for `MultiCamCameraStream`. Everything here
// runs on macOS `swift test`; the AVCaptureMultiCamSession capture path is
// `#if os(iOS)`-gated and exercised on device via the V-harness (Task B5).
import XCTest
@testable import SyncField

final class MultiCamCameraStreamTests: XCTestCase {

    private func makeStream() -> MultiCamCameraStream {
        MultiCamCameraStream(
            videoSettings: .egocentric1080p,
            probedCalibration: nil)
    }

    // MARK: Manifest entries

    func test_manifest_entries_are_uw_then_wide_in_order() {
        let entries = makeStream().manifestEntries(report: nil)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].streamId, "cam_ego")
        XCTAssertEqual(entries[1].streamId, "cam_ego_wide")
        XCTAssertEqual(entries[0].filePath, "cam_ego.mp4")
        XCTAssertEqual(entries[1].filePath, "cam_ego_wide.mp4")
    }

    func test_both_manifest_entries_carry_the_cam_ego_sync_group() {
        let entries = makeStream().manifestEntries(report: nil)
        XCTAssertEqual(entries[0].syncGroupId, "cam_ego")
        XCTAssertEqual(entries[1].syncGroupId, "cam_ego")
    }

    func test_only_wide_entry_advertises_no_audio_track() {
        let entries = makeStream().manifestEntries(report: nil)
        XCTAssertTrue(entries[0].capabilities.providesAudioTrack)   // cam_ego = audio
        XCTAssertFalse(entries[1].capabilities.providesAudioTrack)  // cam_ego_wide = video only
    }

    func test_uw_frame_count_comes_from_the_ingest_report_when_present() {
        let report = StreamIngestReport(
            streamId: "cam_ego", filePath: "cam_ego.mp4", frameCount: 137)
        let entries = makeStream().manifestEntries(report: report)
        XCTAssertEqual(entries[0].frameCount, 137)
    }

    // MARK: Degradation → truncated manifest status

    func test_wide_entry_has_no_status_before_any_degradation() {
        let entries = makeStream().manifestEntries(report: nil)
        XCTAssertNil(entries[0].status)
        XCTAssertNil(entries[1].status)
        XCTAssertNil(entries[1].truncatedAtNs)
    }

    func test_wide_entry_marked_truncated_after_degradation() {
        let cam = makeStream()
        cam.markWideDegraded(atNs: 4_200_000_000, reason: "system_pressure_shutdown")
        let entries = cam.manifestEntries(report: nil)
        // UW leg is untouched — it keeps recording.
        XCTAssertNil(entries[0].status)
        // Wide leg is truncated with the degradation timestamp.
        XCTAssertEqual(entries[1].status, "truncated")
        XCTAssertEqual(entries[1].truncatedAtNs, 4_200_000_000)
    }

    func test_degradation_is_idempotent_first_timestamp_wins() {
        let cam = makeStream()
        cam.markWideDegraded(atNs: 100, reason: "system_pressure_shutdown")
        cam.markWideDegraded(atNs: 999, reason: "wide_frames_stopped")
        let entries = cam.manifestEntries(report: nil)
        XCTAssertEqual(entries[1].truncatedAtNs, 100)
    }

    func test_truncated_wide_entry_serializes_status_and_timestamp_keys() throws {
        let cam = makeStream()
        cam.markWideDegraded(atNs: 4_200_000_000, reason: "session_interruption")
        let manifest = Manifest(
            sdkVersion: "0.11.0", hostId: "h", role: "single",
            streams: cam.manifestEntries(report: nil))
        let data = try JSONEncoder().encode(manifest)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let streams = dict["streams"] as! [[String: Any]]
        // cam_ego has neither key; cam_ego_wide has both.
        XCTAssertFalse(streams[0].keys.contains("status"))
        XCTAssertFalse(streams[0].keys.contains("truncated_at_ns"))
        XCTAssertEqual(streams[1]["status"] as? String, "truncated")
        XCTAssertEqual(streams[1]["truncated_at_ns"] as? UInt64, 4_200_000_000)
    }

    func test_non_truncated_wide_entry_omits_status_keys_for_byte_compat() throws {
        let manifest = Manifest(
            sdkVersion: "0.11.0", hostId: "h", role: "single",
            streams: makeStream().manifestEntries(report: nil))
        let data = try JSONEncoder().encode(manifest)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for entry in dict["streams"] as! [[String: Any]] {
            XCTAssertFalse(entry.keys.contains("status"))
            XCTAssertFalse(entry.keys.contains("truncated_at_ns"))
        }
    }

    // MARK: Degradation handler + event

    func test_handler_receives_degradation_event() {
        let cam = makeStream()
        final class Box: @unchecked Sendable { var event: StereoDegradationEvent? }
        let box = Box()
        cam.setStereoDegradationHandler { box.event = $0 }
        cam.markWideDegraded(atNs: 77, reason: "wide_frames_stopped")
        XCTAssertEqual(box.event?.atNs, 77)
        XCTAssertEqual(box.event?.stream, "cam_ego_wide")
        XCTAssertEqual(box.event?.reason, "wide_frames_stopped")
    }

    func test_handler_fires_only_once_across_repeated_degradation() {
        let cam = makeStream()
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        cam.setStereoDegradationHandler { _ in counter.n += 1 }
        cam.markWideDegraded(atNs: 1, reason: "a")
        cam.markWideDegraded(atNs: 2, reason: "b")
        XCTAssertEqual(counter.n, 1)
    }

    // MARK: StereoDegradationEvent Codable

    func test_degradation_event_round_trips_through_codable() throws {
        let event = StereoDegradationEvent(
            atNs: 123_456_789, stream: "cam_ego_wide", reason: "session_interruption")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StereoDegradationEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func test_degradation_event_uses_snake_case_json_keys() throws {
        let event = StereoDegradationEvent(
            atNs: 42, stream: "cam_ego_wide", reason: "system_pressure_shutdown")
        let dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertEqual(dict["at_ns"] as? UInt64, 42)
        XCTAssertEqual(dict["stream"] as? String, "cam_ego_wide")
        XCTAssertEqual(dict["reason"] as? String, "system_pressure_shutdown")
    }

    // MARK: Support gate (non-iOS host)

    func test_unsupported_reason_is_non_nil_on_non_ios() {
        #if !os(iOS)
        XCTAssertEqual(MultiCamCameraStream.unsupportedReason(), "multicam_unsupported")
        XCTAssertFalse(MultiCamCameraStream.isSupported())
        #endif
    }

    func test_stream_identity_and_capabilities() {
        let cam = makeStream()
        XCTAssertEqual(cam.streamId, "cam_ego")
        XCTAssertTrue(cam.capabilities.producesFile)
        XCTAssertTrue(cam.capabilities.providesAudioTrack)
    }
}
