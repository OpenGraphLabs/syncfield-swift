//
//  EgoTactileViewController.swift
//  syncfield-swift integration example — iPhone + Oglo tactile gloves (L + R)
//
//  Captures:
//    - iPhone back camera  (AVFoundation, H.264 mp4 with mic audio track)
//    - CoreMotion IMU      (100 Hz)
//    - Tactile glove Left  (BLE, 100 Hz, 5 FSR channels + device hw timestamp)
//    - Tactile glove Right (BLE, 100 Hz, 5 FSR channels + device hw timestamp)
//
//  Prerequisites in the host app:
//    - Info.plist: NSCameraUsageDescription, NSMicrophoneUsageDescription,
//      NSMotionUsageDescription, NSBluetoothAlwaysUsageDescription
//

// MARK: - At a glance — the entire SDK contract in 12 lines
//
//     let session = SessionOrchestrator(hostId: "iphone_tactile", outputDirectory: episodesDir)
//     try session.add(iPhoneCameraStream(streamId: "cam_ego"))
//     try session.add(iPhoneMotionStream(streamId: "imu"))
//     try session.add(TactileStream(streamId: "tactile_left",  side: .left))
//     try session.add(TactileStream(streamId: "tactile_right", side: .right))
//
//     try await session.connect()             // BLE scans + pairs both gloves
//     try await session.startRecording()      // atomic start of all four streams
//     _ = try await session.stopRecording()   // closes files; BLE stays connected
//     _ = try await session.ingest { _ in }   // no-op — BLE samples are captured live
//     try await session.disconnect()          // unpairs gloves, closes camera + IMU
//
//     // session.episodeDirectory now contains:
//     //   cam_ego.mp4, cam_ego.timestamps.jsonl, imu.jsonl,
//     //   tactile_left.jsonl, tactile_right.jsonl,
//     //   sync_point.json, manifest.json, session.log
//     //
//     // Ship that directory to your own storage (S3/GCS/your API). Upload is intentionally
//     // left to the host app — the SDK does not manage network transfer to your backend.

#if os(iOS)

import UIKit
import SyncField
import SyncFieldUIKit

final class EgoTactileViewController: UIViewController {

    // Streams
    private let cam   = iPhoneCameraStream(streamId: "cam_ego")
    private let imu   = iPhoneMotionStream(streamId: "imu", rateHz: 100)
    private let left  = TactileStream(streamId: "tactile_left",  side: .left)
    private let right = TactileStream(streamId: "tactile_right", side: .right)

    // Session
    private let session = SessionOrchestrator(
        hostId: "iphone_tactile",
        outputDirectory: FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("episodes", isDirectory: true))

    // Camera preview (optional convenience from SyncFieldUIKit)
    private lazy var preview = SyncFieldPreviewView(stream: cam)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(preview)
        preview.frame = view.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        Task {
            try session.add(cam)
            try session.add(imu)
            try session.add(left)
            try session.add(right)
            try await session.connect()
        }
    }

    @objc func record() {
        Task { try await session.startRecording() }
    }

    @objc func stop() {
        Task {
            _ = try await session.stopRecording()
            _ = try await session.ingest { _ in }
            try await session.disconnect()

            // Hand the episode directory off to your own uploader.
            await uploadEpisode(session.episodeDirectory)
        }
    }

    private func uploadEpisode(_ directory: URL) async {
        // Your storage (S3 / GCS / internal API). The SDK does not upload.
    }
}

#endif
