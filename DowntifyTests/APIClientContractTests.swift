import Foundation
import XCTest
@testable import Downtify

final class APIClientContractTests: XCTestCase {
    func testAddressNormalizationPreservesReverseProxyPath() throws {
        let address = try ServerAddress("  music.example.test:8443/downtify///  ")
        XCTAssertEqual(address.baseURL.absoluteString, "https://music.example.test:8443/downtify")
        XCTAssertEqual(address.url(for: MobileAPIV1.serverInfoPath).path, "/downtify/api/server/info")
    }

    func testAddressRejectsCredentialsAndQuery() {
        XCTAssertThrowsError(try ServerAddress("https://user:secret@example.test"))
        XCTAssertThrowsError(try ServerAddress("https://example.test?token=secret"))
    }

    func testServerInfoUsesPublicV1EndpointAndChecksCompatibility() async throws {
        let loader = StubLoader(body: #"{"product":"Downtify","api_version":1,"server_id":"srv","capabilities":{"password_sign_in":true}}"#)
        let client = APIClient(session: loader)
        let address = try ServerAddress("https://example.test/music")

        let info = try await client.serverInfo(at: address)

        XCTAssertEqual(info.serverID, "srv")
        XCTAssertTrue(info.supportsPasswordSignIn)
        XCTAssertEqual(loader.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(loader.lastRequest?.url?.path, "/music/api/server/info")
        XCTAssertNil(loader.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testWrongProductAndNewerAPIHaveDistinctErrors() async throws {
        let address = try ServerAddress("https://example.test")
        do {
            _ = try await APIClient(session: StubLoader(body: #"{"product":"Other","api_version":1,"server_id":"srv"}"#)).serverInfo(at: address)
            XCTFail("Expected wrong-product error")
        } catch let error as APIError {
            XCTAssertEqual(error, .incompatibleProduct("Other"))
        }

        do {
            _ = try await APIClient(session: StubLoader(body: #"{"product":"Downtify","api_version":2,"server_id":"srv"}"#)).serverInfo(at: address)
            XCTFail("Expected unsupported-version error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unsupportedAPIVersion(2))
        }
    }

    func testHTTPFailurePreservesRetryAfter() async throws {
        let loader = StubLoader(status: 429, headers: ["Retry-After": "12"])
        let client = APIClient(session: loader)
        let address = try ServerAddress("http://music.local")
        do {
            _ = try await client.serverInfo(at: address)
            XCTFail("Expected HTTP error")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(429, retryAfter: 12))
        }
    }

    func testHTTPRequestsRequireExplicitConsentBeforeSending() async throws {
        let loader = StubLoader()
        let address = try ServerAddress("http://music.local")
        var request = URLRequest(url: address.url(for: "/api/private"))
        request.setValue("Bearer private-token", forHTTPHeaderField: "Authorization")

        do {
            _ = try await APIClient(session: loader).send(request, to: address)
            XCTFail("Expected consent requirement")
        } catch let error as APIError {
            XCTAssertEqual(error, .insecureTransportConsentRequired)
        }
        XCTAssertNil(loader.lastRequest)

        _ = try await APIClient(session: loader, allowsInsecureRequests: true)
            .send(request, to: address)
        XCTAssertNotNil(loader.lastRequest)
    }

    func testLyricsFetchRequiresCapabilityAndUsesAuthenticatedV1Route() async throws {
        let info = #"{"product":"Downtify","api_version":1,"server_id":"srv","capabilities":{"lyrics":true}}"#
        let loader = SequenceLoader(bodies: [info, #"{"synced":"[00:01.00]Line","plain":"Line"}"#])
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Music",
                                    deviceID: "device", username: "alice", role: nil, token: "secret", allowsInsecureHTTP: false)

        let lyrics = try await TrackLyricsAPI(transport: loader).fetch(trackID: "track-1", session: session)

        XCTAssertEqual(lyrics, TrackLyrics(synced: "[00:01.00]Line", plain: "Line"))
        XCTAssertEqual(loader.requests.last?.httpMethod, "GET")
        XCTAssertEqual(loader.requests.last?.url?.path, "/music/api/v1/tracks/track-1/lyrics")
        XCTAssertEqual(loader.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testLyricsFetchSkipsRouteWhenCapabilityIsAbsent() async throws {
        let info = #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#
        let loader = SequenceLoader(bodies: [info])
        let session = DeviceSession(baseAddress: "https://example.test", serverID: "srv", serverName: "Music",
                                    deviceID: "device", username: nil, role: nil, token: "secret", allowsInsecureHTTP: false)

        let lyrics = try await TrackLyricsAPI(transport: loader).fetch(trackID: "track-1", session: session)

        XCTAssertNil(lyrics)
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertEqual(loader.requests.first?.url?.path, "/api/server/info")
    }

    func testTrashCapabilityAndPreviewUseAuthenticatedAdminContractRoutes() async throws {
        let loader = SequenceLoader(bodies: [
            #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#,
            #"{"enabled":true,"can_manage":true,"retention_days":30}"#,
            #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#,
            #"{"request_id":"req-1","state":"preparing"}"#,
            #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#,
            #"{"state":"ready","preview":{"confirmation":"confirm-1","items":[{"id":"op-1","file":"Artist/01.flac","track_id":"track-1","metadata":{"title":"Song","artist":"Artist","codec":"flac"},"state":"pending","size":100,"expires_at":null}]}}"#
        ])
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Music",
                                    deviceID: "device", username: "alice", role: "admin", token: "secret", allowsInsecureHTTP: false)
        let api = TrashAPI(transport: loader)
        let capability = try await api.capabilities(session: session)
        XCTAssertTrue(capability.available)
        let (_, preview) = try await api.preview(trackIDs: ["track-1"], session: session)
        XCTAssertEqual(preview.confirmation, "confirm-1")
        XCTAssertEqual(loader.requests.map { $0.url?.path }, [
            "/music/api/server/info",
            "/music/api/v1/library/trash/capabilities",
            "/music/api/server/info",
            "/music/api/v1/library/trash/preview",
            "/music/api/server/info",
            "/music/api/v1/library/trash/preview/req-1"
        ])
        XCTAssertEqual(loader.requests[3].httpMethod, "POST")
        XCTAssertEqual(String(data: loader.requests[3].httpBody!, encoding: .utf8), #"{"track_ids":["track-1"]}"#)
        XCTAssertTrue(loader.requests.filter { $0.url?.path != "/music/api/server/info" }
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
    }

    func testTrashRejectsMismatchedServerBeforeSendingToken() async throws {
        let loader = SequenceLoader(bodies: [#"{"product":"Downtify","api_version":1,"server_id":"other"}"#])
        let session = DeviceSession(baseAddress: "https://example.test", serverID: "srv", serverName: "Music",
                                    deviceID: "device", username: "alice", role: "admin", token: "secret", allowsInsecureHTTP: false)
        do {
            _ = try await TrashAPI(transport: loader).capabilities(session: session)
            XCTFail("Expected identity mismatch")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .differentServer)
        }
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertNil(loader.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testTrashDoesNotSendMutationForNonAdminSession() async throws {
        let loader = SequenceLoader(bodies: [])
        let session = DeviceSession(baseAddress: "https://example.test", serverID: "srv", serverName: "Music",
                                    deviceID: "device", username: "alice", role: "user", token: "secret", allowsInsecureHTTP: false)
        do {
            try await TrashAPI(transport: loader).restore(ids: ["item"], session: session)
            XCTFail("Expected admin role gate")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(403, retryAfter: nil))
        }
        XCTAssertTrue(loader.requests.isEmpty)
    }

    func testTrashPreservesServerErrorCodeForActionableConflict() async throws {
        let info = #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#
        let loader = SequenceLoader(bodies: [info, #"{"detail":{"code":"track_is_playing"}}"#], statuses: [200, 409])
        let session = DeviceSession(baseAddress: "https://example.test", serverID: "srv", serverName: "Music",
                                    deviceID: "device", username: "alice", role: "admin", token: "secret", allowsInsecureHTTP: false)
        do {
            try await TrashAPI(transport: loader).restore(ids: ["item"], session: session)
            XCTFail("Expected server conflict")
        } catch let error as TrashAPIError {
            XCTAssertEqual(error, .httpStatus(409, code: "track_is_playing"))
        }
    }
}

private final class SequenceLoader: HTTPDataLoading {
    private var bodies: [String]
    private var statuses: [Int]
    private(set) var requests: [URLRequest] = []

    init(bodies: [String], statuses: [Int]? = nil) {
        self.bodies = bodies
        self.statuses = statuses ?? Array(repeating: 200, count: bodies.count)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !bodies.isEmpty else { throw APIError.invalidResponse }
        let status = statuses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(bodies.removeFirst().utf8), response)
    }
}

private final class StubLoader: HTTPDataLoading {
    let body: Data
    let status: Int
    let headers: [String: String]
    private(set) var lastRequest: URLRequest?

    init(body: String = "{}", status: Int = 200, headers: [String: String] = [:]) {
        self.body = Data(body.utf8)
        self.status = status
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (body, response)
    }
}
