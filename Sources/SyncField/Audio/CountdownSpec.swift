// Sources/SyncField/Audio/CountdownSpec.swift
import Foundation

/// Optional pre-start countdown UX. Drives a "3, 2, 1, GO!" buildup before
/// `SessionOrchestrator.startRecording` triggers the atomic BLE start and
/// the cross-device sync chirp.
///
/// Two parts work together:
/// - **Audible ticks** (when `style == .audible`) play ascending tones
///   through the iPhone's main speaker so the operator hears the buildup
///   even with the device on a head-mount. They cannot be confused with
///   the start chirp itself (different waveform and frequency band).
/// - **`onTick` callback** (passed into `startRecording`) fires once per
///   tick with `remaining` (3, 2, 1) so your UI can flash the number on
///   screen at the same instant as the audible tone.
///
/// The countdown runs before the BLE start TaskGroup, so the chirp
/// always lands AFTER the last visible/audible tick: 3 → 2 → 1 → CHIRP.
public struct CountdownSpec: Sendable, Equatable {
    public let ticks: Int
    public let intervalMs: Double
    public let style: Style

    public enum Style: Sendable, Equatable {
        /// SDK plays ascending tones (880, 1047, 1175 Hz for a 3-tick
        /// countdown — the same musical interval the egonaut production
        /// rig has been using). Frequencies cycle if `ticks > 3`.
        case audible
        /// No audio. `onTick` is the only signal — use this when your
        /// app handles its own audio cues or wants a purely visual
        /// countdown.
        case silent
    }

    public init(ticks: Int, intervalMs: Double, style: Style) {
        self.ticks = max(0, ticks)
        self.intervalMs = max(50, intervalMs)
        self.style = style
    }

    /// 3-tick countdown, 1 second per tick, audible ascending tones.
    /// Matches the production UX in the egonaut rig.
    public static let standard = CountdownSpec(
        ticks: 3, intervalMs: 1000, style: .audible)

    /// 3-tick countdown, 1 second per tick, no audio. Use when your app
    /// wants only the visual countdown via `onTick`.
    public static let silent = CountdownSpec(
        ticks: 3, intervalMs: 1000, style: .silent)
}
