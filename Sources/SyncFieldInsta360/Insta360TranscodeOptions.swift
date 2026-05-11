import Foundation

/// Camera-side H.264 export configuration. Defaults match the official
/// Insta360 app's "동영상 저장 → 1080P/30FPS" preset, watermark off.
///
/// Used by `Insta360WiFiDownloader.transcodeAndFetch` to instruct the camera
/// to produce a small standard mp4 instead of shipping the raw `.insv` whole.
/// See `docs/superpowers/specs/2026-04-26-fast-insta360-collect-design.md`.
public struct Insta360TranscodeOptions: Sendable {
    public let width: Int32
    public let height: Int32
    public let fps: Double
    public let bitrate: Int32          // bits per second

    public static let `default` = Insta360TranscodeOptions(
        width: 1920, height: 1080, fps: 30.0, bitrate: 10_000_000)

    public init(width: Int32, height: Int32, fps: Double, bitrate: Int32) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }
}
