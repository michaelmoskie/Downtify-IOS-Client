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
