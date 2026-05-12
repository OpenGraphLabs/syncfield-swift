import Foundation

/// Stable identity for a camera the host app has paired before.
///
/// CoreBluetooth UUIDs are useful when iOS still remembers the peripheral, but
/// can rotate across app/device state changes. GO-family BLE names include the
/// stable serial suffix used by Insta360's wake-by-camera API, so production
/// reconnects should carry both values whenever possible.
public struct Insta360KnownCameraIdentity: Sendable, Equatable {
    public let uuid: String?
    public let preferredBLEName: String?
    public let serialLast6: String?

    public init(uuid: String?, bleName: String?) {
        let trimmedUUID = uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = Self.normalizeBLEName(bleName)
        self.uuid = (trimmedUUID?.isEmpty == false) ? trimmedUUID : nil
        self.preferredBLEName = normalizedName
        self.serialLast6 = normalizedName.flatMap {
            Insta360BLEController.extractSerialLast6(fromBLEName: $0)
        }
    }

    public var isUsable: Bool {
        uuid != nil || preferredBLEName != nil || serialLast6 != nil
    }

    /// Key used by the in-process pairing registry. Prefer the CoreBluetooth
    /// UUID when present so existing manual-pair behavior stays unchanged;
    /// fall back to serial/name for saved mappings that only have a BLE name.
    public var bindingKey: String? {
        if let uuid { return uuid }
        if let serialLast6 { return "serial:\(serialLast6)" }
        if let preferredBLEName { return "name:\(preferredBLEName)" }
        return nil
    }

    internal static func normalizeBLEName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
