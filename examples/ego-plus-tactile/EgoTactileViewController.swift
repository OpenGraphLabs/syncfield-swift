//
//  EgoTactileViewController.swift
//  syncfield-swift integration example — iPhone + Oglo tactile gloves (L + R)
//
//  Captures:
//    - iPhone back camera  (AVFoundation, H.264 mp4)
//    - CoreMotion IMU      (100 Hz)
//    - Tactile glove Left  (BLE, 100 Hz, 5 FSR channels + device hw timestamp)
//    - Tactile glove Right (BLE, 100 Hz, 5 FSR channels + device hw timestamp)
//

#if os(iOS)

import UIKit
import SyncField
import SyncFieldUIKit

final class EgoTactileViewController: UIViewController {

    // MARK: Streams

    private let cameraStream = iPhoneCameraStream(streamId: "cam_ego")
    private let motionStream = iPhoneMotionStream(streamId: "imu", rateHz: 100)
    private let leftGlove    = TactileStream(streamId: "tactile_left",  side: .left)
    private let rightGlove   = TactileStream(streamId: "tactile_right", side: .right)

    // MARK: Session

    private let session: SessionOrchestrator = {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("episodes", isDirectory: true)
        return SessionOrchestrator(hostId: "iphone_tactile", outputDirectory: docs)
    }()

    // MARK: UI

    private lazy var preview = SyncFieldPreviewView(stream: cameraStream)
    private let statusLabel  = UILabel()

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(preview)
        view.addSubview(statusLabel)
        Task { await prepare() }
        observeHealth()
    }

    private func prepare() async {
        do {
            try session.add(cameraStream)
            try session.add(motionStream)
            try session.add(leftGlove)    // BLE scan + connect inside connect()
            try session.add(rightGlove)
            try await session.connect()
        } catch {
            presentError(error)
        }
    }

    private func observeHealth() {
        Task { @MainActor in
            for await event in session.healthEvents {
                if case .streamConnected(let id) = event      { statusLabel.text = "\(id) ready" }
                if case .streamDisconnected(let id, _) = event { statusLabel.text = "\(id) lost" }
            }
        }
    }

    // MARK: Actions

    @objc private func recordTapped() {
        Task { try? await session.startRecording() }
    }

    @objc private func stopTapped() {
        Task {
            _ = try? await session.stopRecording()
            _ = try? await session.ingest { _ in }   // BLE data is live → no-op
            let episode = session.episodeDirectory
            try? await session.disconnect()
            await uploadEpisode(episode)
        }
    }

    // MARK: Your upload logic

    private func uploadEpisode(_ directory: URL) async { /* customer-owned */ }

    private func presentError(_ e: Error) { /* UIAlertController omitted */ }
}

#endif
