import Foundation

internal enum Insta360WakeSignal: Equatable, Sendable {
    case targeted(String)
    case broadcast
}

internal struct Insta360WakeRetryPolicy: Sendable {
    /// Official-app-like wake cadence for GO 3S.
    ///
    /// Prefer the specific camera wake when the saved serial is known, but
    /// periodically fall back to broadcast wake. In the field, cameras can
    /// miss the authenticated targeted advert after long sleep or after a
    /// partial reset; broadcast gives the Action Cam low-power radio another
    /// route without requiring the Action Pod screen to power on.
    internal static func signal(serialLast6: String?, cycle: Int) -> Insta360WakeSignal {
        guard let serialLast6, serialLast6.count == 6 else {
            return .broadcast
        }
        return cycle % 3 == 2 ? .broadcast : .targeted(serialLast6)
    }
}
