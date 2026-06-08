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
        XCTAssertEqual(TactileConstants.packetHeaderBytes, 6)
        XCTAssertEqual(TactileConstants.channelsPerSample, 5)
        XCTAssertEqual(TactileConstants.bytesPerSample, 10)
    }

    func test_side_rawValue_matches_manifest_contract() {
        XCTAssertEqual(TactileSide.left.rawValue, "left")
        XCTAssertEqual(TactileSide.right.rawValue, "right")
    }

    func test_manifest_parses_from_firmware_json() throws {
        let json = """
        {"device":"oglo","side":"left","hw_rev":"v1.2","rate_hz":100,
         "channels":[{"id":0,"loc":"thumb","type":"fsr","bits":12},
                     {"id":1,"loc":"index","type":"fsr","bits":12},
                     {"id":2,"loc":"middle","type":"fsr","bits":12},
                     {"id":3,"loc":"ring","type":"fsr","bits":12},
                     {"id":4,"loc":"pinky","type":"fsr","bits":12}]}
        """
        let m = try JSONDecoder().decode(DeviceManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.side, .left)
        XCTAssertEqual(m.rateHz, 100)
        XCTAssertEqual(m.channels.count, 5)
        XCTAssertEqual(m.locationForChannel(0), "thumb")
        XCTAssertEqual(m.locationForChannel(4), "pinky")
        XCTAssertEqual(m.schemaVer, 0)  // legacy
    }

    // schema_ver=4 firmware sends `channels` as a flat string array (not objects),
    // plus values_per_sample / sample_shape. Decoding must not throw.
    func test_manifest_parses_schema_v4_string_channels() throws {
        let json = """
        {"device":"oglo","schema_ver":4,"side":"left","hw_rev":"RDR02_FLEX5_REV_C",
         "rate_hz":100,"samples_per_packet":2,"values_per_sample":80,
         "sample_order":"finger,row,col","sample_shape":[5,4,4],
         "channels":["pinky","ring","middle","index","thumb"]}
        """
        let m = try JSONDecoder().decode(DeviceManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.schemaVer, 4)
        XCTAssertEqual(m.side, .left)
        XCTAssertEqual(m.valuesPerSample, 80)
        XCTAssertEqual(m.samplesPerPacket, 2)
        XCTAssertEqual(m.sampleShape, [5, 4, 4])
        XCTAssertTrue(m.channels.isEmpty)              // no object channels in v4
        XCTAssertEqual(m.fingerLabels, ["pinky", "ring", "middle", "index", "thumb"])
        XCTAssertEqual(m.locationForChannel(0), "pinky")  // finger index → name
        XCTAssertEqual(m.locationForChannel(4), "thumb")
    }
}
