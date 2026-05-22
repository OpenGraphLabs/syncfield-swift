import Foundation

/// One file visible on an Insta360 camera over its WiFi command/HTTP
/// channels. We surface only **video** files (`.mp4` / `.insv`) — wrist
/// captures are always video, and stitching photos in here would force the
/// UI to render two different media kinds. Photos are filtered out at
/// listing time in `Insta360WiFiDownloader`.
public struct Insta360FileInfo: Sendable {
    /// Camera-side absolute URI, e.g. `/DCIM/Camera01/VID_20260522_151156_00_472.mp4`.
    public let fileUri: String

    /// Capture-start ISO8601. Parsed from the filename `VID_YYYYMMDD_HHMMSS`
    /// token and treated as UTC (the camera time is synced from the phone
    /// before each capture, so phone-local wall clock = filename token).
    public let createdAtIso: String

    /// Approximate clip duration in seconds. Derived from
    /// `INSCameraEditInfo.favoriteInfo.modifyTimestamp - filenameStartUnix`.
    /// Within a few hundred ms of true duration on GO3S (the camera writes
    /// modifyTimestamp at stop). 0 when filename or modifyTimestamp is
    /// missing — JS recovery code treats 0 as "unknown" and falls back to
    /// timestamp-only matching.
    public let durationSec: Double

    /// File size in bytes. 0 when the camera's listing API doesn't
    /// populate it (the GO3S edit-list path doesn't carry size; an
    /// optional HEAD pass could fill this in but isn't run on the bulk
    /// listing because of per-file HTTP cost).
    public let sizeBytes: UInt64

    /// `file://` URL of a JPEG thumbnail in the local cache. Populated by
    /// the metadata-enrich pass for the top N candidates closest to the
    /// recovery reference date. nil when enrich was skipped or failed.
    public let thumbnailUri: String?

    /// Camera serial number written into the file's metadata sidecar
    /// (`INSFileMndType.Metadata` → `INSExtraMetadata.serialNumber`). Used
    /// by the JS recovery matcher to verify the candidate file was
    /// produced by the same physical camera the recording session paired
    /// with. nil when the enrich pass didn't run on this file.
    public let cameraSerial: String?

    public init(
        fileUri: String,
        createdAtIso: String,
        durationSec: Double,
        sizeBytes: UInt64,
        thumbnailUri: String? = nil,
        cameraSerial: String? = nil
    ) {
        self.fileUri = fileUri
        self.createdAtIso = createdAtIso
        self.durationSec = durationSec
        self.sizeBytes = sizeBytes
        self.thumbnailUri = thumbnailUri
        self.cameraSerial = cameraSerial
    }

    /// Lightweight copy-with helpers for the enrich pass.
    public func with(thumbnailUri: String?) -> Insta360FileInfo {
        Insta360FileInfo(
            fileUri: fileUri,
            createdAtIso: createdAtIso,
            durationSec: durationSec,
            sizeBytes: sizeBytes,
            thumbnailUri: thumbnailUri,
            cameraSerial: cameraSerial)
    }

    public func with(cameraSerial: String?) -> Insta360FileInfo {
        Insta360FileInfo(
            fileUri: fileUri,
            createdAtIso: createdAtIso,
            durationSec: durationSec,
            sizeBytes: sizeBytes,
            thumbnailUri: thumbnailUri,
            cameraSerial: cameraSerial)
    }
}
