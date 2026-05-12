import XCTest
@testable import SyncFieldInsta360

final class Insta360WakeTests: XCTestCase {
    func test_encodeWakeId_usesUppercaseHexAsciiForSixSerialCharacters() {
        XCTAssertEqual(
            Insta360BLEController.encodeWakeId(serialLast6: "ABCDEF"),
            "414243444546")
        XCTAssertEqual(
            Insta360BLEController.encodeWakeId(serialLast6: "7W3DGW"),
            "375733444757")
    }

    func test_encodeWakeId_ignoresCharactersAfterSix() {
        XCTAssertEqual(
            Insta360BLEController.encodeWakeId(serialLast6: "ABCDEFZZ"),
            "414243444546")
    }

    func test_extractSerialLast6_acceptsGo3SBLEName() {
        XCTAssertEqual(
            Insta360BLEController.extractSerialLast6(fromBLEName: "GO 3S 7W3DGW"),
            "7W3DGW")
    }

    func test_extractSerialLast6_trimsWhitespaceAndRejectsMalformedNames() {
        XCTAssertEqual(
            Insta360BLEController.extractSerialLast6(fromBLEName: "  GO 3S ABC123  "),
            "ABC123")
        XCTAssertNil(Insta360BLEController.extractSerialLast6(fromBLEName: "GO 3S ABC12"))
        XCTAssertNil(Insta360BLEController.extractSerialLast6(fromBLEName: ""))
    }

    func test_knownCameraIdentity_prefersStableSerialForWake() {
        let identity = Insta360KnownCameraIdentity(
            uuid: "4F7C2B4A-23D0-4F94-A9E4-0ED3C6C93E51",
            bleName: " GO   3S   7W3DGW ")

        XCTAssertEqual(identity.serialLast6, "7W3DGW")
        XCTAssertEqual(identity.preferredBLEName, "GO 3S 7W3DGW")
        XCTAssertEqual(identity.bindingKey, "4F7C2B4A-23D0-4F94-A9E4-0ED3C6C93E51")
    }

    func test_knownCameraIdentity_usesNameBindingWhenUUIDIsMissing() {
        let identity = Insta360KnownCameraIdentity(
            uuid: "",
            bleName: "GO 3S 2BNMWH")

        XCTAssertEqual(identity.serialLast6, "2BNMWH")
        XCTAssertEqual(identity.bindingKey, "serial:2BNMWH")
        XCTAssertTrue(identity.isUsable)
    }

    func test_knownCameraIdentity_rejectsEmptyIdentity() {
        let identity = Insta360KnownCameraIdentity(uuid: " ", bleName: "\n")
        XCTAssertFalse(identity.isUsable)
        XCTAssertNil(identity.bindingKey)
    }

    func test_wakeRetryPolicyFallsBackToBroadcastAfterTargetedBursts() {
        XCTAssertEqual(
            Insta360WakeRetryPolicy.signal(serialLast6: "1TEBJJ", cycle: 0),
            .targeted("1TEBJJ"))
        XCTAssertEqual(
            Insta360WakeRetryPolicy.signal(serialLast6: "1TEBJJ", cycle: 1),
            .targeted("1TEBJJ"))
        XCTAssertEqual(
            Insta360WakeRetryPolicy.signal(serialLast6: "1TEBJJ", cycle: 2),
            .broadcast)
    }

    func test_commandReadinessPolicyHardGatesRecordingOnOptionsProbe() {
        XCTAssertEqual(
            Insta360CommandReadinessPolicy.probe(for: "refreshConnection"),
            .commandChannel)
        XCTAssertEqual(
            Insta360CommandReadinessPolicy.probe(for: "startRemoteRecording attempt 1"),
            .commandChannel)
        XCTAssertEqual(
            Insta360CommandReadinessPolicy.probe(for: "stopRemoteRecording"),
            .bleLinkOnly)
        XCTAssertEqual(
            Insta360CommandReadinessPolicy.probe(for: "startCapture attempt 1 failed cleanup"),
            .bleLinkOnly)
    }

    func test_commandReadinessPolicyKeepsOptionsProbeForOptionReads() {
        XCTAssertEqual(
            Insta360CommandReadinessPolicy.probe(for: "wifiCredentials"),
            .commandChannel)
        XCTAssertEqual(
            Insta360CommandReadinessPolicy.probe(for: "enableWiFiForDownload"),
            .commandChannel)
    }

    func test_withTimeoutReturnsOnDeadlineEvenWhenSDKCallbackArrivesLater() async {
        let started = Date()
        do {
            try await Insta360BLEController.withTimeout(seconds: 0.05) {
                try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        cont.resume(returning: ())
                    }
                }
            }
            XCTFail("expected timeout")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 0.25)
        }
    }

    func test_identityStorePersistsRecordsAndFindsByUUID() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insta360_identity_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = Insta360IdentityStore(directory: dir, keychainService: "test.syncfield.\(UUID().uuidString)")
        let record = Insta360IdentityStore.Record(
            serialLast6: "7W3DGW",
            lastKnownUUID: "UUID-OLD",
            lastKnownBLEName: "GO 3S 7W3DGW",
            firstPairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2))

        await first.upsert(record)

        let second = Insta360IdentityStore(directory: dir, keychainService: "test.syncfield.\(UUID().uuidString)")
        let bySerial = await second.record(forSerial: "7W3DGW")
        let byUUID = await second.record(forUUID: "UUID-OLD")

        XCTAssertEqual(bySerial?.lastKnownBLEName, "GO 3S 7W3DGW")
        XCTAssertEqual(byUUID?.serialLast6, "7W3DGW")
    }
}
