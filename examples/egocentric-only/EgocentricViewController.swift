//
//  EgocentricViewController.swift
//  syncfield-swift integration example — iPhone-only recording
//
//  Captures:
//    - iPhone back camera  (AVFoundation, H.264 mp4)
//    - CoreMotion IMU      (100 Hz accelerometer + gyroscope + magnetometer)
//
//  Copy this file into your app, wire the Record / Stop buttons,
//  and plug your own upload logic into `uploadEpisode(_:)`.
//

#if os(iOS)

import UIKit
import SyncField
import SyncFieldUIKit

final class EgocentricViewController: UIViewController {

    // MARK: Streams

    private let cameraStream = iPhoneCameraStream(streamId: "cam_ego")
    private let motionStream = iPhoneMotionStream(streamId: "imu", rateHz: 100)

    // MARK: Session

    private let session: SessionOrchestrator = {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("episodes", isDirectory: true)
        return SessionOrchestrator(hostId: "iphone_ego", outputDirectory: docs)
    }()

    // MARK: UI

    private lazy var preview = SyncFieldPreviewView(stream: cameraStream)
    private let recordButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        layoutUI()
        Task { await prepareSession() }
    }

    private func prepareSession() async {
        do {
            try session.add(cameraStream)
            try session.add(motionStream)
            try await session.connect()   // camera + IMU ready, preview live
        } catch {
            presentError(error)
        }
    }

    // MARK: Actions

    @objc private func recordTapped() {
        Task {
            do { _ = try await session.startRecording() }
            catch { presentError(error) }
        }
    }

    @objc private func stopTapped() {
        Task {
            do {
                _ = try await session.stopRecording()
                _ = try await session.ingest { _ in }   // no-op (all native)
                let episode = session.episodeDirectory
                try await session.disconnect()
                await uploadEpisode(episode)
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Your upload logic goes here

    private func uploadEpisode(_ directory: URL) async {
        // Ship `directory` to S3/GCS/your internal API and enqueue a
        // sync job against the syncfield server. The SDK intentionally
        // does not bundle an uploader.
    }

    // MARK: Boilerplate

    private func layoutUI() {
        preview.frame = view.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(preview)

        recordButton.setTitle("Record", for: .normal)
        stopButton.setTitle("Stop", for: .normal)
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        // ... add to view, Auto Layout omitted for brevity ...
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: "SyncField error",
                                      message: String(describing: error),
                                      preferredStyle: .alert)
        alert.addAction(.init(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

#endif
