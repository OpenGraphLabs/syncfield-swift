//
//  EgoWristViewController.swift
//  syncfield-swift integration example — iPhone + Insta360 Go 3S wrist camera
//
//  Captures:
//    - iPhone back camera  (AVFoundation, H.264 mp4 with mic audio track)
//    - CoreMotion IMU      (100 Hz)
//    - Insta360 Go 3S      (BLE remote trigger + automatic WiFi download in ingest())
//
//  Prerequisites in the host app:
//    - INSCameraServiceSDK.xcframework linked (Embed & Sign)
//    - Capability: Hotspot Configuration
//    - Info.plist: NSBluetoothAlwaysUsageDescription, NSCameraUsageDescription,
//      NSMicrophoneUsageDescription, NSMotionUsageDescription,
//      NSLocationWhenInUseUsageDescription
//

// MARK: - At a glance — the entire SDK contract in 12 lines
//
//     let session = SessionOrchestrator(hostId: "iphone_rig", outputDirectory: episodesDir)
//     try session.add(iPhoneCameraStream(streamId: "cam_ego"))
//     try session.add(iPhoneMotionStream(streamId: "imu"))
//     try session.add(Insta360CameraStream(streamId: "cam_wrist"))
//
//     try await session.connect()             // opens devices; BLE-pairs the Insta360
//     try await session.startRecording()      // atomic: iPhone AVAssetWriter + Insta360 BLE trigger
//     _ = try await session.stopRecording()   // closes iPhone file; stops Insta360 remote recording
//     _ = try await session.ingest { p in     // switches to camera WiFi, downloads mp4, restores WiFi
//         print("\(p.streamId): \(Int(p.fraction * 100))%")
//     }
//     try await session.disconnect()          // tears everything down
//
//     // session.episodeDirectory now contains:
//     //   cam_ego.mp4, cam_ego.timestamps.jsonl, cam_wrist.mp4, cam_wrist.anchor.json,
//     //   imu.jsonl, sync_point.json, manifest.json, session.log
//     //
//     // Ship that directory to your own storage (S3/GCS/your API). Upload is intentionally
//     // left to the host app — the SDK does not manage network transfer to your backend.

#if os(iOS)

    import UIKit
    import SyncField
    import SyncFieldUIKit
    import SyncFieldInsta360

    final class EgoWristViewController: UIViewController {

        // Streams
        private let cam = iPhoneCameraStream(streamId: "cam_ego")
        private let imu = iPhoneMotionStream(streamId: "imu", rateHz: 100)
        private let wrist = Insta360CameraStream(streamId: "cam_wrist")

        // Session
        private let session = SessionOrchestrator(
            hostId: "iphone_rig",
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
                try session.add(wrist)
                try await session.connect()
            }
        }

        @objc func record() {
            Task { try await session.startRecording() }
        }

        @objc func stop() {
            Task {
                _ = try await session.stopRecording()
                _ = try await session.ingest { p in
                    print("\(p.streamId): \(Int(p.fraction * 100))%")
                }
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
