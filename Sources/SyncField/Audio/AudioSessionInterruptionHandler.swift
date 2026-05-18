// Sources/SyncField/Audio/AudioSessionInterruptionHandler.swift
import Foundation
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// Subscribes to `AVAudioSession.interruptionNotification` and calls
/// `onRecover` exactly once per `.ended` event.
///
/// `.began` is ignored — iOS deactivates the session on its own; our job
/// is to resume cleanly when the interruption ends. The recovery sequence
/// (re-applying the session configuration, reattaching capture audio
/// inputs) is the caller's responsibility because only the caller knows
/// which streams need to be touched.
///
/// The notification fires from an arbitrary thread; we hop onto a private
/// serial queue so observers don't race with each other and `onRecover`
/// can do `await` work without blocking the notification dispatch.
public final class AudioSessionInterruptionHandler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "syncfield.audio.interruption",
                                       qos: .userInitiated)
    private var token: NSObjectProtocol?
    private let onRecover: @Sendable () async -> Void

    public init(onRecover: @escaping @Sendable () async -> Void) {
        self.onRecover = onRecover
    }

    public func start() {
        #if canImport(AVFoundation) && os(iOS)
        // Idempotent: starting twice would double-fire. Remove any prior
        // observer first.
        if let t = token { NotificationCenter.default.removeObserver(t) }
        token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.queue.async { self?.handle(note) }
        }
        #endif
    }

    public func stop() {
        if let t = token { NotificationCenter.default.removeObserver(t) }
        token = nil
    }

    deinit { stop() }

    #if canImport(AVFoundation) && os(iOS)
    private func handle(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        guard type == .ended else { return }
        let recover = onRecover
        Task { await recover() }
    }
    #endif
}
