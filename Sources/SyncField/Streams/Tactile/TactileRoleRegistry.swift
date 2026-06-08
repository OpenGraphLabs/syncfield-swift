// Sources/SyncField/Streams/Tactile/TactileRoleRegistry.swift
import Foundation

/// Coordinates which physical glove (peripheral identifier) is bound to which
/// side across the two concurrent `TactileStream`s (left + right). Without this,
/// both streams could race to grab the same "oglo" peripheral during scan, or
/// bind the wrong glove. Mirrors the role-claim pattern used by Insta360RoleRegistry.
///
/// Actor-isolated so the two streams' claim/release calls are serialised.
public actor TactileRoleRegistry {
    public static let shared = TactileRoleRegistry()

    private var claimed: [String: TactileSide] = [:]   // peripheral uuidString -> side

    public init() {}

    /// Atomically bind `id` to `side`. Returns false if `id` is already bound to a
    /// different side, or if `side` is already held by a different peripheral.
    public func tryClaim(_ id: String, side: TactileSide) -> Bool {
        if let existing = claimed[id] { return existing == side }
        if claimed.contains(where: { $0.value == side }) { return false }
        claimed[id] = side
        return true
    }

    /// Identifiers already claimed by any side — used to exclude them from a scan.
    public func claimedIds() -> Set<String> { Set(claimed.keys) }

    public func release(id: String) { claimed.removeValue(forKey: id) }

    public func release(side: TactileSide) {
        claimed = claimed.filter { $0.value != side }
    }
}
