import XCTest
@testable import SyncFieldInsta360

final class Insta360CollectorTests: XCTestCase {

    // MARK: - Helpers

    private func sidecar(streamId: String,
                          bleUuid: String,
                          bleAckNs: UInt64 = 0) -> Insta360PendingSidecar {
        Insta360PendingSidecar(
            streamId: streamId,
            cameraFileURI: "file:///\(streamId)",
            bleUuid: bleUuid,
            bleName: "GO 3S \(bleUuid)",
            role: streamId.hasSuffix("_left") ? "left" : "right",
            bleAckMonotonicNs: bleAckNs,
            savedAt: "2026-05-11T00:00:00Z")
    }

    private func item(at path: String,
                       streamId: String,
                       bleUuid: String,
                       bleAckNs: UInt64 = 0) -> Insta360PendingSidecar.WithDir {
        Insta360PendingSidecar.WithDir(
            episodeDir: URL(fileURLWithPath: path),
            sidecar: sidecar(streamId: streamId, bleUuid: bleUuid, bleAckNs: bleAckNs))
    }

    // MARK: - groupByCamera

    func test_groupByCamera_groupsItemsByUUID() {
        let items = [
            item(at: "/ep_A", streamId: "cam_wrist_left",  bleUuid: "U_LEFT"),
            item(at: "/ep_A", streamId: "cam_wrist_right", bleUuid: "U_RIGHT"),
            item(at: "/ep_B", streamId: "cam_wrist_left",  bleUuid: "U_LEFT"),
            item(at: "/ep_B", streamId: "cam_wrist_right", bleUuid: "U_RIGHT"),
        ]

        let grouped = Insta360Collector.groupByCamera(items)

        XCTAssertEqual(grouped.count, 2, "two physical cameras → two groups")
        let left  = grouped.first { $0.uuid == "U_LEFT" }!
        let right = grouped.first { $0.uuid == "U_RIGHT" }!
        XCTAssertEqual(left.items.count, 2)
        XCTAssertEqual(right.items.count, 2)
    }

    func test_groupByCamera_emitsDeterministicOrder() {
        // Same set of items in two orderings must produce the same
        // grouped output — required so a batch collect that retries
        // can resume reliably.
        let a = item(at: "/ep_B", streamId: "cam_wrist_left",  bleUuid: "U_LEFT")
        let b = item(at: "/ep_A", streamId: "cam_wrist_right", bleUuid: "U_RIGHT")
        let c = item(at: "/ep_A", streamId: "cam_wrist_left",  bleUuid: "U_LEFT")

        let g1 = Insta360Collector.groupByCamera([a, b, c])
        let g2 = Insta360Collector.groupByCamera([c, a, b])

        XCTAssertEqual(g1.map(\.uuid), g2.map(\.uuid))
        for (lhs, rhs) in zip(g1, g2) {
            XCTAssertEqual(
                lhs.items.map { $0.sidecar.streamId },
                rhs.items.map { $0.sidecar.streamId })
            XCTAssertEqual(
                lhs.items.map { $0.episodeDir.path },
                rhs.items.map { $0.episodeDir.path })
        }
    }

    func test_groupByCamera_singleCamera_singleItem() {
        let items = [
            item(at: "/ep_A", streamId: "cam_wrist", bleUuid: "U_ONLY"),
        ]
        let grouped = Insta360Collector.groupByCamera(items)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].uuid, "U_ONLY")
        XCTAssertEqual(grouped[0].items.count, 1)
    }

    func test_groupByCamera_emptyInput_returnsEmpty() {
        XCTAssertTrue(Insta360Collector.groupByCamera([]).isEmpty)
    }

    func test_groupByCamera_preservesSidecarData() {
        let items = [
            item(at: "/ep_X", streamId: "cam_wrist_left",
                  bleUuid: "U_LEFT", bleAckNs: 42),
        ]
        let grouped = Insta360Collector.groupByCamera(items)
        XCTAssertEqual(grouped[0].items[0].sidecar.bleAckMonotonicNs, 42)
        XCTAssertEqual(grouped[0].items[0].sidecar.cameraFileURI,
                       "file:///cam_wrist_left")
    }

    func test_itemsForEpisodeDirs_scansOnlyRequestedEpisodeDirs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector_requested_\(UUID().uuidString)")
        let epA = root.appendingPathComponent("ep_A")
        let epB = root.appendingPathComponent("ep_B")
        let epIgnored = root.appendingPathComponent("ep_ignored")
        for dir in [epA, epB, epIgnored] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSidecar(to: epA, streamId: "cam_wrist_left", bleUuid: "U_LEFT")
        try writeSidecar(to: epB, streamId: "cam_wrist_right", bleUuid: "U_RIGHT")
        try writeSidecar(to: epIgnored, streamId: "cam_wrist_ignored", bleUuid: "U_IGNORED")

        let items = try Insta360Collector.itemsForEpisodeDirs([epB, epA])

        XCTAssertEqual(Set(items.map { $0.episodeDir.lastPathComponent }), ["ep_A", "ep_B"])
        XCTAssertEqual(Set(items.map { $0.sidecar.streamId }), ["cam_wrist_left", "cam_wrist_right"])
    }

    private func writeSidecar(to episodeDir: URL,
                              streamId: String,
                              bleUuid: String) throws {
        try Insta360PendingSidecar.write(
            to: episodeDir,
            streamId: streamId,
            cameraFileURI: "file:///\(streamId)",
            bleUuid: bleUuid,
            bleName: "GO 3S \(bleUuid)",
            role: streamId.hasSuffix("_left") ? "left" : "right",
            bleAckNs: 0)
    }

    // MARK: - Standalone API surface (no SDK linked → framework-not-linked path)

    #if !canImport(INSCameraServiceSDK)
    func test_collectEpisode_emptyDir_returnsEmptyWithoutFrameworkError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // An empty episode dir has no pendings — the collector must
        // short-circuit BEFORE reaching the framework-guarded path so
        // host apps that ship without the Insta360 SDK can call this
        // safely (no-op).
        let results = try await Insta360Collector.shared.collectEpisode(dir)
        XCTAssertTrue(results.isEmpty)
    }

    func test_collectAll_emptyRoot_returnsEmptyWithoutFrameworkError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let results = try await Insta360Collector.shared.collectAll(root: dir)
        XCTAssertTrue(results.isEmpty)
    }
    #endif
}
