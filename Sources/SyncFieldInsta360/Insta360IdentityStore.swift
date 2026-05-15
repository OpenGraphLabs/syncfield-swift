import Foundation
import Security

/// Disk-backed cache for Insta360 camera identity that survives app cold starts.
///
/// CoreBluetooth peripheral UUIDs may rotate across launches, but the BLE
/// advertised camera name contains the stable serial suffix we need for
/// wake-by-serial. This store keeps both so callers can accept either identity.
internal actor Insta360IdentityStore {
    internal static let shared = Insta360IdentityStore()

    internal struct Record: Codable, Sendable, Equatable {
        let serialLast6: String
        var lastKnownUUID: String?
        var lastKnownBLEName: String
        var firstPairedAt: Date
        var lastSeenAt: Date
        var phoneAuthorizedAt: Date?
        var phoneAuthorizationFailedAt: Date?

        init(
            serialLast6: String,
            lastKnownUUID: String?,
            lastKnownBLEName: String,
            firstPairedAt: Date,
            lastSeenAt: Date,
            phoneAuthorizedAt: Date? = nil,
            phoneAuthorizationFailedAt: Date? = nil
        ) {
            self.serialLast6 = serialLast6
            self.lastKnownUUID = lastKnownUUID
            self.lastKnownBLEName = lastKnownBLEName
            self.firstPairedAt = firstPairedAt
            self.lastSeenAt = lastSeenAt
            self.phoneAuthorizedAt = phoneAuthorizedAt
            self.phoneAuthorizationFailedAt = phoneAuthorizationFailedAt
        }
    }

    private let recordsURL: URL
    private let keychainService: String
    private var records: [String: Record] = [:]

    internal init(
        directory: URL? = nil,
        keychainService: String = "syncfield.insta360"
    ) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            dir = appSupport.appendingPathComponent(
                "SyncFieldInsta360",
                isDirectory: true)
        }

        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true)
        self.recordsURL = dir.appendingPathComponent("identities.json")
        self.keychainService = keychainService
        self.records = Self.loadRecords(from: recordsURL)
    }

    internal func upsert(_ record: Record) {
        records[record.serialLast6] = record
        saveToDisk()
    }

    internal func upsert(
        serialLast6: String,
        uuid: String?,
        bleName: String,
        now: Date = Date()
    ) {
        guard serialLast6.count == 6, !bleName.isEmpty else { return }
        var record = records[serialLast6] ?? Record(
            serialLast6: serialLast6,
            lastKnownUUID: uuid,
            lastKnownBLEName: bleName,
            firstPairedAt: now,
            lastSeenAt: now)
        record.lastKnownUUID = uuid ?? record.lastKnownUUID
        record.lastKnownBLEName = bleName
        record.lastSeenAt = now
        records[serialLast6] = record
        saveToDisk()
    }

    internal func touch(serialLast6: String, now: Date = Date()) {
        guard var record = records[serialLast6] else { return }
        record.lastSeenAt = now
        records[serialLast6] = record
        saveToDisk()
    }

    internal func record(forSerial serial: String) -> Record? {
        records[serial]
    }

    internal func record(forUUID uuid: String) -> Record? {
        records.values.first { $0.lastKnownUUID == uuid }
    }

    internal func all() -> [Record] {
        Array(records.values)
    }

    internal func remove(serialLast6: String) {
        records.removeValue(forKey: serialLast6)
        saveToDisk()
    }

    internal func clear() {
        records.removeAll()
        saveToDisk()
    }

    internal func markPhoneAuthorized(serialLast6: String, at: Date = Date()) {
        guard var record = records[serialLast6] else { return }
        record.phoneAuthorizedAt = at
        record.phoneAuthorizationFailedAt = nil
        record.lastSeenAt = at
        records[serialLast6] = record
        saveToDisk()
    }

    internal func clearPhoneAuthorization(serialLast6: String, at: Date = Date()) {
        guard var record = records[serialLast6] else { return }
        record.phoneAuthorizedAt = nil
        record.phoneAuthorizationFailedAt = at
        record.lastSeenAt = at
        records[serialLast6] = record
        saveToDisk()
    }

    internal func isPhoneAuthorized(serialLast6: String) -> Bool {
        records[serialLast6]?.phoneAuthorizedAt != nil
    }

    internal func wifiCreds(forSerial serial: String) -> (ssid: String, passphrase: String)? {
        KeychainHelper.read(
            service: keychainService,
            account: "wifi.\(serial)"
        ).flatMap(Self.decodeCredentials)
    }

    internal func setWifiCreds(
        _ creds: (ssid: String, passphrase: String),
        forSerial serial: String
    ) {
        let data = Self.encodeCredentials(creds)
        KeychainHelper.write(
            service: keychainService,
            account: "wifi.\(serial)",
            data: data)
    }

    internal func removeWifiCreds(forSerial serial: String) {
        KeychainHelper.delete(
            service: keychainService,
            account: "wifi.\(serial)")
    }

    internal static func cachedPhoneAuthorizationState(
        uuid: String?,
        bleName: String?,
        directory: URL? = nil
    ) -> PhoneAuthorizationCacheState {
        let records = loadRecords(from: recordsURL(directory: directory))
        let serial = bleName.flatMap(Insta360BLEController.extractSerialLast6(fromBLEName:))
        let record: Record? = {
            if let serial, let match = records[serial] {
                return match
            }
            if let uuid, let match = records.values.first(where: { $0.lastKnownUUID == uuid }) {
                return match
            }
            if let serial {
                return records.values.first { $0.serialLast6 == serial }
            }
            return nil
        }()

        guard let record else { return .unknown }
        if let authorizedAt = record.phoneAuthorizedAt {
            return .authorized(at: authorizedAt)
        }
        if record.phoneAuthorizationFailedAt != nil {
            return .failed
        }
        return .unknown
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent(
            "SyncFieldInsta360",
            isDirectory: true)
    }

    private static func recordsURL(directory: URL?) -> URL {
        (directory ?? defaultDirectory()).appendingPathComponent("identities.json")
    }

    private static func loadRecords(from url: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: [.atomic])
    }

    private static func encodeCredentials(
        _ creds: (ssid: String, passphrase: String)
    ) -> Data {
        let dict = ["ssid": creds.ssid, "passphrase": creds.passphrase]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private static func decodeCredentials(
        _ data: Data
    ) -> (ssid: String, passphrase: String)? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ssid = dict["ssid"],
              let passphrase = dict["passphrase"],
              !ssid.isEmpty
        else { return nil }
        return (ssid, passphrase)
    }
}

private enum KeychainHelper {
    static func read(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(service: String, account: String, data: Data) {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }

        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
