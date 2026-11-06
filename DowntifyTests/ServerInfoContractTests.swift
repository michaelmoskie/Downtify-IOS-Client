import Foundation
import XCTest
@testable import Downtify

final class ServerInfoContractTests: XCTestCase {
    func testSupportedServerWithPasswordSignIn() throws {
        let info = try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{"password_sign_in":true}}"#)

        XCTAssertTrue(info.isCompatible)
        XCTAssertTrue(info.supportsPasswordSignIn)
        XCTAssertEqual(info.serverID, "server-1")
    }

    func testPasswordSignInRequiresExplicitCapability() throws {
        let fixtures = [
            #"{"product":"Downtify","api_version":1,"server_id":"server-1"}"#,
            #"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{}}"#,
            #"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{"password_sign_in":false}}"#
        ]

        for fixture in fixtures {
            let info = try decode(fixture)
            XCTAssertTrue(info.isCompatible)
            XCTAssertFalse(info.supportsPasswordSignIn)
        }
    }

    func testPodcastsRequireExplicitServerCapability() throws {
        XCTAssertFalse(try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1"}"#).supportsPodcasts)
        XCTAssertFalse(try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{"podcasts":false}}"#).supportsPodcasts)
        XCTAssertTrue(try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{"podcasts":true}}"#).supportsPodcasts)
    }

    func testLyricsCapabilityAndLRCTimingParsing() throws {
        XCTAssertFalse(try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1"}"#).supportsLyrics)
        XCTAssertFalse(try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{"lyrics":false}}"#).supportsLyrics)
        XCTAssertTrue(try decode(#"{"product":"Downtify","api_version":1,"server_id":"server-1","capabilities":{"lyrics":true}}"#).supportsLyrics)

        let lines = LyricLine.parse("[00:01.20]First\n[00:03.005]Second\n[00:03.50]Third\n[00:04.00][00:05.25]Repeated")
        XCTAssertEqual(lines.map(\.text), ["First", "Second", "Third", "Repeated", "Repeated"])
        XCTAssertEqual(lines.map(\.time), [1.2, 3.005, 3.5, 4.0, 5.25])
    }

    func testIncompatibleServers() throws {
        let fixtures = [
            #"{"product":"Downtify","api_version":2,"server_id":"server-1"}"#,
            #"{"product":"Other","api_version":1,"server_id":"server-1"}"#
        ]

        for fixture in fixtures {
            XCTAssertFalse(try decode(fixture).isCompatible)
        }
    }

    private func decode(_ fixture: String) throws -> MobileAPIV1.ServerInfoDTO {
        try JSONDecoder().decode(MobileAPIV1.ServerInfoDTO.self, from: Data(fixture.utf8))
    }
}
