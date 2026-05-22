import XCTest
@testable import SyncFieldInsta360

/// Pure-function coverage for the per-file metadata parser added to
/// `Insta360WiFiDownloader`. The full WiFi flow needs a real camera (and is
/// exercised by the metadata probe); these tests pin the deterministic
/// protobuf walker that production ego↔wrist mapping depends on.
final class Insta360WiFiDownloaderTests: XCTestCase {

    // MARK: parseInsta360ExtraMetadata — real GO3S payload heads from probe

    /// Decoded head256 of `VID_20260522_151156_00_472.mp4` captured by the
    /// probe on real hardware. Field 1 = serial "IATEF2602BNMWH", field 9
    /// (varint) = 41,943,040 bytes (~40 MB), field 10 (varint) = 15 sec.
    private static let realVideoMetadataHead: [UInt8] = [
        // field 1 (string): "IATEF2602BNMWH"
        0x0a, 0x0e,
        0x49, 0x41, 0x54, 0x45, 0x46, 0x32, 0x36, 0x30, 0x32,
        0x42, 0x4e, 0x4d, 0x57, 0x48,
        // field 2 (string): "Insta360 GO 3S"
        0x12, 0x0e,
        0x49, 0x6e, 0x73, 0x74, 0x61, 0x33, 0x36, 0x30, 0x20,
        0x47, 0x4f, 0x20, 0x33, 0x53,
        // field 3 (string): "v9.0.23_build1"
        0x1a, 0x0e,
        0x76, 0x39, 0x2e, 0x30, 0x2e, 0x32, 0x33, 0x5f, 0x62,
        0x75, 0x69, 0x6c, 0x64, 0x31,
        // field 5 (string, len 63) — calibration offset. Real probe
        // payload: "1_2528.728_2019.850_1547.644_-0.091_0.149_90.352_4056_3040_1135"
        // (63 bytes, exactly what the camera writes — note no trailing
        // "8" inside this field; the next byte is the field 7 tag = 0x38).
        0x2a, 0x3f,
        0x31, 0x5f, 0x32, 0x35, 0x32, 0x38, 0x2e, 0x37, 0x32, 0x38,
        0x5f, 0x32, 0x30, 0x31, 0x39, 0x2e, 0x38, 0x35, 0x30, 0x5f,
        0x31, 0x35, 0x34, 0x37, 0x2e, 0x36, 0x34, 0x34, 0x5f, 0x2d,
        0x30, 0x2e, 0x30, 0x39, 0x31, 0x5f, 0x30, 0x2e, 0x31, 0x34,
        0x39, 0x5f, 0x39, 0x30, 0x2e, 0x33, 0x35, 0x32, 0x5f, 0x34,
        0x30, 0x35, 0x36, 0x5f, 0x33, 0x30, 0x34, 0x30, 0x5f, 0x31,
        0x31, 0x33, 0x35,
        // field 7 (varint, 7 bytes) — opaque 64-bit ID/timestamp
        0x38,
        0xf4, 0x99, 0xe7, 0xa9, 0xd4, 0xcd, 0x04,
        // field 9 (varint) = fileSize bytes — 4 bytes encode 41,943,040
        0x48,
        0x80, 0x80, 0x80, 0x14,
        // field 10 (varint) = durationSec — 1 byte: 15
        0x50, 0x0f,
    ]

    func test_parseMetadata_realPayload_extractsSerial() {
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(
            Data(Self.realVideoMetadataHead))
        XCTAssertEqual(meta.serialNumber, "IATEF2602BNMWH")
    }

    func test_parseMetadata_realPayload_extractsFileSize() {
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(
            Data(Self.realVideoMetadataHead))
        XCTAssertEqual(meta.sizeBytes, 41_943_040)
    }

    func test_parseMetadata_realPayload_extractsDuration() {
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(
            Data(Self.realVideoMetadataHead))
        XCTAssertEqual(meta.durationSec, 15.0)
    }

    func test_parseMetadata_lrvPayload_sameSerialDifferentSize() {
        // LRV preview for the same recording — 20 MB instead of 40 MB,
        // same serial. The fileSize varint is the last 4 bytes before the
        // field 10 (duration) tag+value pair, so it sits at indices
        // [count-6 .. count-3].
        var bytes = Self.realVideoMetadataHead
        let trailerByteIdx = bytes.count - 3
        XCTAssertEqual(bytes[trailerByteIdx], 0x14,
                       "Test array structure changed — recheck fileSize varint position")
        bytes[trailerByteIdx] = 0x0a

        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(Data(bytes))
        XCTAssertEqual(meta.serialNumber, "IATEF2602BNMWH")
        XCTAssertEqual(meta.sizeBytes, 20_971_520)
        XCTAssertEqual(meta.durationSec, 15.0)
    }

    // MARK: parseInsta360ExtraMetadata — synthetic edge cases

    func test_parseMetadata_returnsEmptyForEmptyData() {
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(Data())
        XCTAssertNil(meta.serialNumber)
        XCTAssertNil(meta.durationSec)
        XCTAssertNil(meta.sizeBytes)
    }

    func test_parseMetadata_recoversFromUnknownTag() {
        // Field 9 (size=99), then an unknown varint field 16 (tag 0x80 0x01),
        // then field 10 (duration=8).
        let bytes: [UInt8] = [
            0x48, 0x63,              // field 9 varint = 99
            0x80, 0x01, 0x2a,        // field 16 varint = 42 (unknown, skipped)
            0x50, 0x08,              // field 10 varint = 8
        ]
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(Data(bytes))
        XCTAssertEqual(meta.sizeBytes, 99)
        XCTAssertEqual(meta.durationSec, 8.0)
    }

    func test_parseMetadata_doesNotCrashOnTruncatedVarint() {
        // Continuation byte without a follow-up — walker should bail
        // cleanly and surface only the field it managed to read.
        let bytes: [UInt8] = [
            0x50, 0x05,        // field 10 = 5
            0x48, 0x80,        // field 9 starts (continuation), then EOF
        ]
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(Data(bytes))
        XCTAssertEqual(meta.durationSec, 5.0)
        XCTAssertNil(meta.sizeBytes)
    }

    func test_parseMetadata_skipsLengthDelimitedNonSerial() {
        // Field 2 (string "Insta360 GO 3S"), then field 9 = 42.
        let payload: [UInt8] = Array("Insta360 GO 3S".utf8)
        var bytes: [UInt8] = [0x12, UInt8(payload.count)]
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: [0x48, 0x2a]) // field 9 = 42

        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(Data(bytes))
        XCTAssertNil(meta.serialNumber) // field 1 missing
        XCTAssertEqual(meta.sizeBytes, 42)
    }

    func test_parseMetadata_handlesFixed64() {
        // Field 1 string, then a fixed64 (tag wire-type 1), then field 10.
        let bytes: [UInt8] = [
            0x0a, 0x02, 0x41, 0x42,                         // field 1 = "AB"
            0x49, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // field 9 fixed64
            0x50, 0x07,                                     // field 10 = 7
        ]
        let meta = Insta360WiFiDownloader.parseInsta360ExtraMetadata(Data(bytes))
        XCTAssertEqual(meta.serialNumber, "AB")
        XCTAssertEqual(meta.durationSec, 7.0)
    }

    // MARK: readVarint primitive

    func test_readVarint_singleByte() {
        XCTAssertEqual(Insta360WiFiDownloader.readVarint(Data([0x0f]), at: 0)?.0, 15)
    }

    func test_readVarint_multiByte() {
        // 0x80 0x80 0x80 0x14 = 0x14 << 21 = 41,943,040
        let result = Insta360WiFiDownloader.readVarint(
            Data([0x80, 0x80, 0x80, 0x14]), at: 0)
        XCTAssertEqual(result?.0, 41_943_040)
        XCTAssertEqual(result?.1, 4)
    }

    func test_readVarint_returnsNilOnTruncation() {
        XCTAssertNil(Insta360WiFiDownloader.readVarint(Data([0x80, 0x80]), at: 0))
    }

    // MARK: sanitize() — domain-realistic range guards
    //
    // These guard against schema drift: Insta360 may re-assign which
    // protobuf field number carries duration / fileSize in a future
    // firmware. The wire format stays decodable but the semantics shift.
    // Sanity ranges turn nonsense values into `nil` so the UI shows
    // "unknown" rather than trusting drift-corrupted data.

    func test_sanitize_acceptsRealisticValues() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(
            serialNumber: "IATEF2602BNMWH",
            durationSec: 15.0,
            sizeBytes: 41_943_040)
        let out = Insta360WiFiDownloader.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    func test_sanitize_rejectsNegativeDuration() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(durationSec: -1)
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).durationSec)
    }

    func test_sanitize_rejectsZeroDuration() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(durationSec: 0)
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).durationSec)
    }

    func test_sanitize_rejectsOverSixHourDuration() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(durationSec: 7 * 3600)
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).durationSec)
    }

    func test_sanitize_acceptsBoundaryDurations() {
        let lo = Insta360WiFiDownloader.Insta360ExtraMetadata(durationSec: 0.05)
        let hi = Insta360WiFiDownloader.Insta360ExtraMetadata(durationSec: 6 * 3600)
        XCTAssertEqual(Insta360WiFiDownloader.sanitize(lo).durationSec, 0.05)
        XCTAssertEqual(Insta360WiFiDownloader.sanitize(hi).durationSec, 6 * 3600)
    }

    func test_sanitize_rejectsTinyFileSize() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(sizeBytes: 100)
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).sizeBytes)
    }

    func test_sanitize_rejectsTerabyteFileSize() {
        // 1 TB — well above the 16 GB FAT32 single-file ceiling on a
        // GO3S card. Either we read the wrong field or the camera is
        // lying; treat as unknown either way.
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(
            sizeBytes: 1_099_511_627_776)
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).sizeBytes)
    }

    func test_sanitize_acceptsBoundaryFileSizes() {
        let lo = Insta360WiFiDownloader.Insta360ExtraMetadata(sizeBytes: 10_000)
        let hi = Insta360WiFiDownloader.Insta360ExtraMetadata(
            sizeBytes: 16 * 1_073_741_824)
        XCTAssertEqual(Insta360WiFiDownloader.sanitize(lo).sizeBytes, 10_000)
        XCTAssertEqual(
            Insta360WiFiDownloader.sanitize(hi).sizeBytes,
            16 * 1_073_741_824)
    }

    func test_sanitize_rejectsNonPrintableSerial() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(
            serialNumber: "AB\u{0001}CD")
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).serialNumber)
    }

    func test_sanitize_rejectsTooShortSerial() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(serialNumber: "AB")
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).serialNumber)
    }

    func test_sanitize_rejectsTooLongSerial() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(
            serialNumber: String(repeating: "A", count: 64))
        XCTAssertNil(Insta360WiFiDownloader.sanitize(raw).serialNumber)
    }

    func test_sanitize_acceptsTypicalSerial() {
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(
            serialNumber: "IATEF2602BNMWH")
        XCTAssertEqual(
            Insta360WiFiDownloader.sanitize(raw).serialNumber,
            "IATEF2602BNMWH")
    }

    func test_sanitize_isPerFieldIndependent() {
        // Bad duration shouldn't drop a good fileSize or serial — every
        // field is validated independently so a single drifted field
        // doesn't silently corrupt the others.
        let raw = Insta360WiFiDownloader.Insta360ExtraMetadata(
            serialNumber: "IATEF2602BNMWH",
            durationSec: 99999,         // bad — exceeds 6h
            sizeBytes: 41_943_040)      // good
        let out = Insta360WiFiDownloader.sanitize(raw)
        XCTAssertEqual(out.serialNumber, "IATEF2602BNMWH")
        XCTAssertNil(out.durationSec)
        XCTAssertEqual(out.sizeBytes, 41_943_040)
    }
}
