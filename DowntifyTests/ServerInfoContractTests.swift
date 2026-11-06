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
