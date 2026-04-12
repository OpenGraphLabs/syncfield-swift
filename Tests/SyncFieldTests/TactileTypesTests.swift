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
    }
}
