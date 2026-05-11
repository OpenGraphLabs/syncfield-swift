// Sources/SyncField/Audio/AudioSessionPolicy.swift
import Foundation

#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// How `SessionOrchestrator` manages `AVAudioSession`.
///
/// The sync chirp is the SyncField service's audio-domain alignment marker.
/// For it to be picked up by every nearby microphone (the iPhone's own when
/// `iPhoneCameraStream` is recording, every Insta360 wrist camera's via
/// ambient sound), it must emit from the **iPhone's main loudspeaker**.
/// iOS will route audio to the earpiece or to connected Bluetooth earbuds
/// unless the audio session is configured otherwise.
///
/// The default `.managedBySDK` makes that routing automatic. Pass
/// `.manualByHost` only if your app already owns `AVAudioSession`
/// configuration end-to-end.
public enum AudioSessionPolicy: Sendable {
    /// `SessionOrchestrator.connect()` configures `AVAudioSession` with
    /// `.playAndRecord`, mode `.videoRecording`, options `[.defaultToSpeaker,
    /// .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]`, and activates it.
    /// This guarantees the start/stop chirp emits from the main speaker even
    /// when BT earbuds are connected, and keeps simultaneous mic capture
    /// working in the iPhone camera mp4 audio track.
    case managedBySDK

    /// Skip all `AVAudioSession` configuration. The host app is responsible
    /// for ensuring the session is in a state that can play and record at
    /// the same time, and that audio is routed to the main speaker.
    case manualByHost
}

#if canImport(AVFoundation) && os(iOS)

/// Apply the SDK's standard configuration to `AVAudioSession.sharedInstance()`.
/// Idempotent. Throws on Apple framework error so callers can decide how to
/// surface the failure; `SessionOrchestrator` logs and continues so a quirky
/// audio session doesn't block the whole recording.
///
/// Notable absences:
///   - `.allowBluetooth` and `.allowBluetoothA2DP` are deliberately NOT in
///     the options. Insta360 Go-family cameras connect through BLE for
///     control, and on iOS 18 the active BLE peripheral can cause the
///     output route to drift away from the main speaker mid-session,
///     silencing the start chirp specifically (the BLE startCapture
///     round-trip happens during the same window as the chirp emission).
///     The chirp must reach every nearby microphone, including those of
///     the wrist Insta360s; routing it to BT earbuds would defeat the
///     sync mechanism, so we exclude BT routing entirely.
public enum SyncFieldAudioSession {
    public static func applyManagedConfig() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true, options: [])
        // Force the speaker as the active output port even after
        // setCategory configures `.defaultToSpeaker`. iOS occasionally
        // routes audio through a different port when AVCaptureSession
        // is starting under `.videoRecording` mode with an active BLE
        // peripheral; the explicit override is belt-and-suspenders.
        try session.overrideOutputAudioPort(.speaker)
    }
}

#endif
