import XCTest
@testable import SyncFieldInsta360

final class Insta360ConnectionStateTests: XCTestCase {

    func testAcceptsCommandsOnlyInLiveStates() {
        let live: [Insta360ConnectionState] = [.bleReady, .bleDegraded, .wifiBound]
        for s in live {
            XCTAssertTrue(s.acceptsCommands, "\(s) should accept commands")
        }
        let blocked: [Insta360ConnectionState] = [
            .idle, .searching, .connecting, .bleSuspended,
            .reconnecting, .lost, .giveUp,
        ]
        for s in blocked {
            XCTAssertFalse(s.acceptsCommands, "\(s) should NOT accept commands")
        }
    }

    func testTerminalStatesAreLostAndGiveUp() {
        XCTAssertTrue(Insta360ConnectionState.lost.isTerminal)
        XCTAssertTrue(Insta360ConnectionState.giveUp.isTerminal)
        for s: Insta360ConnectionState in [
            .idle, .searching, .connecting, .bleReady, .bleDegraded,
            .wifiBound, .bleSuspended, .reconnecting,
        ] {
            XCTAssertFalse(s.isTerminal, "\(s) should not be terminal")
        }
    }

    func testRawValuesAreRNStable() {
        // RN consumers switch on these strings; protect with an explicit
        // contract test so refactors don't silently change them.
        XCTAssertEqual(Insta360ConnectionState.idle.rawValue,         "idle")
        XCTAssertEqual(Insta360ConnectionState.searching.rawValue,    "searching")
        XCTAssertEqual(Insta360ConnectionState.connecting.rawValue,   "connecting")
        XCTAssertEqual(Insta360ConnectionState.bleReady.rawValue,     "bleReady")
        XCTAssertEqual(Insta360ConnectionState.bleDegraded.rawValue,  "bleDegraded")
        XCTAssertEqual(Insta360ConnectionState.wifiBound.rawValue,    "wifiBound")
        XCTAssertEqual(Insta360ConnectionState.bleSuspended.rawValue, "bleSuspended")
        XCTAssertEqual(Insta360ConnectionState.reconnecting.rawValue, "reconnecting")
        XCTAssertEqual(Insta360ConnectionState.lost.rawValue,         "lost")
        XCTAssertEqual(Insta360ConnectionState.giveUp.rawValue,       "giveUp")
    }
}
