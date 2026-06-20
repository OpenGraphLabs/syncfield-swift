// Tests/SyncFieldTests/TactileTypesTests.swift
import XCTest
@testable import SyncField

final class TactileTypesTests: XCTestCase {
    func test_constants_match_firmware() {
        XCTAssertEqual(TactileConstants.serviceUUID.uuidString,
                       "4652535F-424C-4500-0000-000000000001")
        XCTAssertEqual(TactileConstants.sensorCharUUID.uuidString,
                       "4652535F-424C-4500-0001-000000000001")
        XCTAssertEqual(TactileConstants.configCharUUID.uuidString,
                       "4652535F-424C-4500-0002-000000000001")
        XCTAssertEqual(TactileConstants.nameFilter, "oglo")
        XCTAssertEqual(TactileConstants.canonicalFingerOrder,
                       ["thumb", "index", "middle", "ring", "pinky"])
        // schema_ver 5 (packed12_v5) geometry.
        XCTAssertEqual(TactileConstants.schemaVer, 5)
        XCTAssertEqual(TactileConstants.v5HeaderBytes, 10)
        XCTAssertEqual(TactileConstants.v5TaxelPackedBytes, 120)
        XCTAssertEqual(TactileConstants.v5ImuRawBytes, 12)
        XCTAssertEqual(TactileConstants.v5SampleStride, 134)
        XCTAssertEqual(TactileConstants.v5FlagPacked, 0x04)
        XCTAssertEqual(TactileConstants.defaultValuesPerSample, 80)
    }

    func test_side_rawValue_matches_manifest_contract() {
        XCTAssertEqual(TactileSide.left.rawValue, "left")
        XCTAssertEqual(TactileSide.right.rawValue, "right")
    }

    // schema_ver 5 firmware sends `channels` as a flat string array (side-aware finger
    // order), plus values_per_sample / sample_shape / packet_format. Decoding the
    // manifest must surface those fields.
    func test_manifest_parses_schema_v5() throws {
        let json = """
        {"device":"oglo","schema_ver":5,"packet_format":"packed12_v5","side":"left",
         "taxel_bits":12,"rate_hz":100,"samples_per_packet":3,"values_per_sample":80,
         "imu_per_sample":true,"imu_layout":"ax,ay,az,gx,gy,gz",
         "sample_order":"finger,row,col","sample_shape":[5,4,4],
         "channels":["pinky","ring","middle","index","thumb"],
         "serial":"OGLO-RDR02A-000001","fw_rev":"0.7.1-cfgfit"}
        """
        let m = try JSONDecoder().decode(DeviceManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.schemaVer, 5)
        XCTAssertEqual(m.packetFormat, "packed12_v5")
        XCTAssertEqual(m.side, .left)
        XCTAssertEqual(m.valuesPerSample, 80)
        XCTAssertEqual(m.samplesPerPacket, 3)
        XCTAssertEqual(m.sampleShape, [5, 4, 4])
        XCTAssertEqual(m.fingerLabels, ["pinky", "ring", "middle", "index", "thumb"])
    }

    // Missing channels → falls back to the canonical finger order (no throw).
    func test_manifest_defaults_finger_order_when_channels_absent() throws {
        let json = """
        {"device":"oglo","schema_ver":5,"side":"right","rate_hz":100,"values_per_sample":80}
        """
        let m = try JSONDecoder().decode(DeviceManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.side, .right)
        XCTAssertEqual(m.fingerLabels, TactileConstants.canonicalFingerOrder)
    }
}
