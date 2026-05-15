import XCTest
@testable import SyncFieldInsta360

final class Insta360IdentityStoreTests: XCTestCase {
    func test_phoneAuthorizationRoundTripsThroughDisk() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authorizedAt = Date(timeIntervalSince1970: 1_775_000_000)

        let first = Insta360IdentityStore(
            directory: dir,
            keychainService: "test.syncfield.\(UUID().uuidString)")
        await first.upsert(
            serialLast6: "7W3DGW",
            uuid: "UUID-A",
            bleName: "GO 3S 7W3DGW")
        await first.markPhoneAuthorized(serialLast6: "7W3DGW", at: authorizedAt)

        let second = Insta360IdentityStore(
            directory: dir,
            keychainService: "test.syncfield.\(UUID().uuidString)")
        let record = await second.record(forSerial: "7W3DGW")
        let isAuthorized = await second.isPhoneAuthorized(serialLast6: "7W3DGW")

        XCTAssertEqual(record?.phoneAuthorizedAt, authorizedAt)
        XCTAssertTrue(isAuthorized)
    }

    func test_clearPhoneAuthorizationMarksCacheAsFailed() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = Insta360IdentityStore(
            directory: dir,
            keychainService: "test.syncfield.\(UUID().uuidString)")
        await store.upsert(
            serialLast6: "7W3DGW",
            uuid: "UUID-A",
            bleName: "GO 3S 7W3DGW")
        await store.markPhoneAuthorized(
            serialLast6: "7W3DGW",
            at: Date(timeIntervalSince1970: 10))
        await store.clearPhoneAuthorization(
            serialLast6: "7W3DGW",
            at: Date(timeIntervalSince1970: 20))

        let record = await store.record(forSerial: "7W3DGW")
        let isAuthorized = await store.isPhoneAuthorized(serialLast6: "7W3DGW")
        XCTAssertNil(record?.phoneAuthorizedAt)
        XCTAssertEqual(record?.phoneAuthorizationFailedAt, Date(timeIntervalSince1970: 20))
        XCTAssertFalse(isAuthorized)
    }

    func test_cachedPhoneAuthorizationStateFindsRecordByRotatedUUIDName() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authorizedAt = Date(timeIntervalSince1970: 100)

        let store = Insta360IdentityStore(
            directory: dir,
            keychainService: "test.syncfield.\(UUID().uuidString)")
        await store.upsert(
            serialLast6: "7W3DGW",
            uuid: "UUID-OLD",
            bleName: "GO 3S 7W3DGW")
        await store.markPhoneAuthorized(serialLast6: "7W3DGW", at: authorizedAt)

        XCTAssertEqual(
            Insta360IdentityStore.cachedPhoneAuthorizationState(
                uuid: "UUID-NEW",
                bleName: "GO 3S 7W3DGW",
                directory: dir),
            .authorized(at: authorizedAt))
    }

    func test_cachedPhoneAuthorizationStateDecodesLegacyRecordAsUnknown() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
          "7W3DGW": {
            "serialLast6": "7W3DGW",
            "lastKnownUUID": "UUID-A",
            "lastKnownBLEName": "GO 3S 7W3DGW",
            "firstPairedAt": 10,
            "lastSeenAt": 20
          }
        }
        """
        try json.data(using: .utf8)!.write(
            to: dir.appendingPathComponent("identities.json"))

        XCTAssertEqual(
            Insta360IdentityStore.cachedPhoneAuthorizationState(
                uuid: "UUID-A",
                bleName: nil,
                directory: dir),
            .unknown)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("insta360_identity_\(UUID().uuidString)", isDirectory: true)
    }
}
