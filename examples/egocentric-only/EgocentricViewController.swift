//
//  EgocentricViewController.swift
//  syncfield-swift integration example — iPhone-only recording
//
//  Captures:
//    - iPhone back camera  (AVFoundation, H.264 mp4 with mic audio track)
//    - CoreMotion IMU      (100 Hz accelerometer + gyroscope + magnetometer)
//
//  Prerequisites in the host app:
//    - Info.plist: NSCameraUsageDescription, NSMicrophoneUsageDescription,
//      NSMotionUsageDescription
//

// MARK: - At a glance — the entire SDK contract in 10 lines
//
//     let session = SessionOrchestrator(hostId: "iphone_ego", outputDirectory: episodesDir)
//     try session.add(iPhoneCameraStream(streamId: "cam_ego"))
//     try session.add(iPhoneMotionStream(streamId: "imu"))
//
//     try await session.connect()             // opens camera + IMU; preview is live
//     try await session.startRecording()      // atomic start of both streams
//     _ = try await session.stopRecording()   // closes AVAssetWriter + CoreMotion
//     _ = try await session.ingest { _ in }   // no-op for native streams
//     try await session.disconnect()          // tears everything down
//
//     // session.episodeDirectory now contains:
//     //   cam_ego.mp4, cam_ego.timestamps.jsonl, imu.jsonl,
//     //   sync_point.json, manifest.json, session.log
//     //
//     // Ship that directory to your own storage (S3/GCS/your API). Upload is intentionally
//     // left to the host app — the SDK does not manage network transfer to your backend.

#if os(iOS)

import UIKit
import SyncField
import SyncFieldUIKit

final class EgocentricViewController: UIViewController {

    // Streams
    private let cam = iPhoneCameraStream(streamId: "cam_ego")
    private let imu = iPhoneMotionStream(streamId: "imu", rateHz: 100)

    // Session
    private let session = SessionOrchestrator(
        hostId: "iphone_ego",
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
