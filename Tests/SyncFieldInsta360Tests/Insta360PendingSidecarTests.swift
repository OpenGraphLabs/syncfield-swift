import XCTest
@testable import SyncFieldInsta360

final class Insta360PendingSidecarTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_writeThenScan_roundTrip() throws {
        try Insta360PendingSidecar.write(
            to: tempDir,
            streamId: "cam_wrist_left",
            cameraFileURI: "file:///DCIM/VID_01.insv",
            bleUuid: "AAAA",
            bleName: "GO 3S A",
            role: "left",
            bleAckNs: 1_234_567_890)

        let scanned = try Insta360PendingSidecar.scan(tempDir)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned[0].streamId, "cam_wrist_left")
        XCTAssertEqual(scanned[0].cameraFileURI, "file:///DCIM/VID_01.insv")
        XCTAssertEqual(scanned[0].bleUuid, "AAAA")
        XCTAssertEqual(scanned[0].role, "left")
        XCTAssertEqual(scanned[0].bleAckMonotonicNs, 1_234_567_890)
    }

    func test_scan_ignoresNonPendingJson() throws {
        try "{\"hi\":1}".write(
            to: tempDir.appendingPathComponent("unrelated.json"),
            atomically: true,
            encoding: .utf8)
        try "{\"stream_id\":\"x\"}".write(
            to: tempDir.appendingPathComponent("cam_wrist_left.anchor.json"),
            atomically: true,
            encoding: .utf8)

        XCTAssertTrue(try Insta360PendingSidecar.scan(tempDir).isEmpty)
    }

    func test_delete_removesSingleSidecar() throws {
        try Insta360PendingSidecar.write(
            to: tempDir,
            streamId: "cam_wrist_left",
            cameraFileURI: "file:///L",
            bleUuid: "A",
            bleName: "A",
            role: "left",
            bleAckNs: 1)
        try Insta360PendingSidecar.delete(at: tempDir, streamId: "cam_wrist_left")

        XCTAssertTrue(try Insta360PendingSidecar.scan(tempDir).isEmpty)
    }

    // MARK: - scanRecursive

    func test_scanRecursive_findsPendingsAcrossEpisodes() throws {
        let epA = tempDir.appendingPathComponent("rec_1/ep_aaa")
        let epB = tempDir.appendingPathComponent("rec_1/ep_bbb")
        try FileManager.default.createDirectory(at: epA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: epB, withIntermediateDirectories: true)

        try Insta360PendingSidecar.write(
            to: epA, streamId: "cam_wrist_left",
            cameraFileURI: "file:///A_L", bleUuid: "U_A", bleName: "A",
            role: "left", bleAckNs: 100)
        try Insta360PendingSidecar.write(
            to: epB, streamId: "cam_wrist_right",
            cameraFileURI: "file:///B_R", bleUuid: "U_B", bleName: "B",
            role: "right", bleAckNs: 200)

        let found = Insta360PendingSidecar.scanRecursive(root: tempDir)
        XCTAssertEqual(found.count, 2)
        let epAResolved = epA.resolvingSymlinksInPath().path
        let epBResolved = epB.resolvingSymlinksInPath().path
        XCTAssertTrue(found.contains {
            $0.episodeDir.resolvingSymlinksInPath().path == epAResolved
            && $0.sidecar.bleUuid == "U_A"
        })
        XCTAssertTrue(found.contains {
            $0.episodeDir.resolvingSymlinksInPath().path == epBResolved
            && $0.sidecar.bleUuid == "U_B"
        })
    }
}
