//
//  EgoWristViewController.swift
//  syncfield-swift integration example — iPhone + Insta360 Go 3S wrist camera
//
//  Captures:
//    - iPhone back camera  (AVFoundation, H.264 mp4)
//    - CoreMotion IMU      (100 Hz)
//    - Insta360 Go 3S      (BLE remote trigger; file downloaded over WiFi in `ingest()`)
//
//  Requires the Insta360 SDK (INSCameraSDK.xcframework) in your app bundle.
//

import UIKit
import SyncField
import SyncFieldUIKit
import SyncFieldInsta360

final class EgoWristViewController: UIViewController {

    // MARK: Streams

    private let cameraStream = iPhoneCameraStream(streamId: "cam_ego")
    private let motionStream = iPhoneMotionStream(streamId: "imu", rateHz: 100)
    private let wristStream  = Insta360CameraStream(streamId: "cam_wrist")

    // MARK: Session

    private let session: SessionOrchestrator = {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("episodes", isDirectory: true)
        return SessionOrchestrator(hostId: "iphone_rig", outputDirectory: docs)
    }()

    // MARK: UI

    private lazy var preview = SyncFieldPreviewView(stream: cameraStream)
    private let progressBar  = UIProgressView(progressViewStyle: .default)

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(preview)
        view.addSubview(progressBar)
        Task { await prepare() }
        observeHealth()
    }

    private func prepare() async {
        do {
            try session.add(cameraStream)
            try session.add(motionStream)
            try session.add(wristStream)         // BLE pairing happens in connect()
            try await session.connect()
        } catch {
            presentError(error)
        }
    }

    private func observeHealth() {
        Task { @MainActor in
            for await event in session.healthEvents {
                switch event {
                case .streamConnected(let id):          log("✅ \(id) connected")
                case .streamDisconnected(let id, let r): log("⚠️ \(id) disconnected: \(r)")
                case .samplesDropped(let id, let n):     log("⚠️ \(id) dropped \(n)")
                case .ingestFailed(let id, let e):       log("❌ \(id) ingest failed: \(e)")
                default: break
                }
            }
        }
    }

    // MARK: Actions

    @objc private func recordTapped() {
        Task {
            do { _ = try await session.startRecording() }  // atomic: BLE trigger + iPhone record
            catch { presentError(error) }
        }
    }

    @objc private func stopTapped() {
        Task {
            do {
                _ = try await session.stopRecording()   // iPhone file closes; Insta360 BLE stop

                // Insta360: switch to camera's WiFi AP, download mp4, copy into episode dir.
                let report = try await session.ingest { [progressBar] progress in
                    Task { @MainActor in
                        progressBar.setProgress(Float(progress.fraction), animated: true)
                    }
                }

                // Even if Insta360 download failed, iPhone streams are usable.
                if case .failure(let err) = report.streamResults["cam_wrist"] ?? .success(.init()) {
                    log("wrist download failed — episode still usable without it: \(err)")
                }

                let episode = session.episodeDirectory
                try await session.disconnect()
                await uploadEpisode(episode)
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Your upload logic

    private func uploadEpisode(_ directory: URL) async { /* customer-owned */ }

    // MARK: Helpers

    private func log(_ s: String) { print("[sync] \(s)") }
    private func presentError(_ e: Error) { /* UIAlertController omitted */ }
}
