import Foundation

public struct Insta360FileInfo: Sendable {
    public let fileUri: String
    public let createdAtIso: String
    public let durationSec: Double
    public let sizeBytes: UInt64
    public let thumbnailUri: String?

    public init(
        fileUri: String,
        createdAtIso: String,
        durationSec: Double,
        sizeBytes: UInt64,
        thumbnailUri: String? = nil
    ) {
        self.fileUri = fileUri
        self.createdAtIso = createdAtIso
        self.durationSec = durationSec
        self.sizeBytes = sizeBytes
        self.thumbnailUri = thumbnailUri
    }
}
