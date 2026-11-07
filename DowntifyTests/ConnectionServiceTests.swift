import Foundation
import XCTest
@testable import Downtify

final class ConnectionServiceTests: XCTestCase {
    @MainActor
    func testArtworkChecksServerIdentityBeforeSendingBearerToken() async throws {
        let store = MemorySessionStore()
        try store.save(DeviceSession(baseAddress: "https://music.local/app", serverID: "server-id",
            serverName: "Server", deviceID: "device-id", username: "maria", role: nil,
            token: "test-token", allowsInsecureHTTP: false))
        let track = LibraryTrack(id: "track-id", file: "", title: "Song", artist: "Artist", artists: [],
            album: "Album", albumArtist: "", albumID: "", artistID: "", trackNumber: 0, year: "",
            duration: 0, codec: "", bitrate: 0, sampleRate: 0, channels: 0, size: 0, added: 0,
            hasCover: true, isExplicit: false, playlists: [])
        let transport = ScriptedConnectionTransport([.serverInfo, .init()])
        let connection = ConnectionService(transport: transport, store: store)
        let artwork = ArtworkLoader(connection: connection, transport: transport)
        _ = await artwork.image(for: track, size: 150)
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/app/api/server/info", "/app/api/v1/tracks/track-id/cover"])
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(transport.requests.last?.url?.query, "size=150")

        let wrong = ScriptedConnectionTransport([.init(body: #"{"product":"Downtify","server_id":"other","api_version":1}"#)])
        let guarded = ArtworkLoader(connection: connection, transport: wrong)
        _ = await guarded.image(for: track, size: 150)
        XCTAssertEqual(wrong.requests.count, 1)
        XCTAssertNil(wrong.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAuthenticationCooldownCountsDownAndExpires() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cooldown = AuthenticationCooldown(seconds: 2.2, now: now)

        XCTAssertEqual(cooldown.remainingSeconds(at: now), 3)
        XCTAssertEqual(cooldown.remainingSeconds(at: now.addingTimeInterval(1.3)), 1)
        XCTAssertEqual(cooldown.remainingSeconds(at: now.addingTimeInterval(3)), 0)
    }

    func testQRPayloadUsesNormalizedAddressAndRejectsAmbiguousParameters() throws {
        let payload = try PairingPayload("downtify://pair?url=https%3A%2F%2FMUSIC.local%3A8443%2Fapp%2F&sid=server-id&code=ABCD-EFGH")
        XCTAssertEqual(payload.address.baseURL.absoluteString, "https://music.local:8443/app")
        XCTAssertEqual(payload.serverID, "server-id")
        XCTAssertEqual(payload.code, "ABCD-EFGH")

        XCTAssertThrowsError(try PairingPayload("downtify://pair?url=https://music.local&sid=server-id&code=A&code=B"))
        XCTAssertThrowsError(try PairingPayload("downtify://pair?url=https://user:password@music.local&sid=server-id&code=A"))
    }

    func testQRChecksServerIDBeforeSendingPairingCode() async throws {
        let loader = ScriptedConnectionTransport([.serverInfo])
        let service = ConnectionService(transport: loader, store: MemorySessionStore())
        let payload = try PairingPayload("downtify://pair?url=https://music.local&sid=wrong-server&code=ABCD-EFGH")

        await assertError(ConnectionError.differentServer) {
            try await service.pair(payload, deviceName: "Test iPhone")
        }
        XCTAssertEqual(loader.requests.map { $0.url?.path }, ["/api/server/info"])
    }

    func testPairingSavesTheCheckedServerAndRestoresAfterRestart() async throws {
        let loader = ScriptedConnectionTransport([.serverInfo, .session])
        let store = KeychainSessionStore(service: "app.downtify.ios.tests.\(UUID())")
        defer { try? store.clear() }
        let service = ConnectionService(transport: loader, store: store)
        let payload = try PairingPayload("downtify://pair?url=https://music.local/app&sid=server-id&code=ABCD-EFGH")

        let session = try await service.pair(payload, deviceName: "Test iPhone")
        XCTAssertEqual(session.serverName, "Checked server name")
        XCTAssertEqual(session.deviceID, "device-id")
        XCTAssertEqual(session.username, "maria")
        XCTAssertEqual(loader.requests.last?.url?.path, "/app/api/auth/pair")
        XCTAssertEqual(loader.requests.last?.httpMethod, "POST")
        XCTAssertEqual(try body(of: loader.requests.last), [
            "code": "ABCD-EFGH", "device_name": "Test iPhone", "platform": "ios"
        ])

        let restarted = ConnectionService(transport: loader, store: store)
        let restored = try await restarted.restoreSession()
        XCTAssertEqual(restored, session)
        try await restarted.signOut()
        try await restarted.signOut()
        let signedOut = try await service.restoreSession()
        XCTAssertNil(signedOut)
    }

    func testPasswordCapabilityGatesSignInOnOlderServers() async throws {
        let loader = ScriptedConnectionTransport([.init(body: #"{"product":"Downtify","server_id":"server-id","api_version":1}"#)])
        let service = ConnectionService(transport: loader, store: MemorySessionStore())
        let target = try await service.probe("music.local")
        await assertError(ConnectionError.passwordSignInUnavailable) {
            try await service.signIn(username: "maria", password: "password", at: target, deviceName: "Test iPhone")
        }
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testPasswordSignInCanReplaceTheKeychainSession() async throws {
        let loader = ScriptedConnectionTransport([
            .serverInfo, .session,
            .init(body: #"{"token":"updated-token","device":{"id":"new-device"}}"#)
        ])
        let store = KeychainSessionStore(service: "app.downtify.ios.tests.\(UUID())")
        defer { try? store.clear() }
        let service = ConnectionService(transport: loader, store: store)
        let target = try await service.probe("music.local")
        _ = try await service.pair(code: "ABCD-EFGH", at: target, deviceName: "Test iPhone")

        let signedIn = try await service.signIn(username: "maria", password: "password", at: target, deviceName: "Test iPhone")
        XCTAssertEqual(signedIn.deviceID, "new-device")
        XCTAssertEqual(signedIn.serverID, target.info.serverID)
        XCTAssertEqual(signedIn.serverName, target.info.name)
        let stored = try await service.restoreSession()
        XCTAssertEqual(stored, signedIn)
    }

    func testAuthenticationMapsEndpointSpecificErrorsAndRetryAfter() async throws {
        let loader = ScriptedConnectionTransport([
            .serverInfo, .init(status: 401), .init(status: 409), .init(status: 401),
            .init(status: 429, headers: ["Retry-After": "24"]), .init(status: 429)
        ])
        let service = ConnectionService(transport: loader, store: MemorySessionStore())
        let target = try await service.probe("music.local")

        await assertError(ConnectionError.wrongCredentials) {
            try await service.signIn(username: " maria ", password: " exact password ", at: target, deviceName: "Test iPhone")
        }
        XCTAssertEqual(loader.requests.last?.url?.path, "/api/auth/token")
        XCTAssertEqual(try body(of: loader.requests.last), [
            "username": "maria", "password": " exact password ", "device_name": "Test iPhone", "platform": "ios"
        ])
        await assertError(ConnectionError.passwordSignInUnavailable) {
            try await service.signIn(username: "maria", password: "password", at: target, deviceName: "Test iPhone")
        }
        for error: ConnectionError in [.wrongCode, .rateLimited(retryAfter: 24), .rateLimited(retryAfter: 60)] {
            await assertError(error) {
                try await service.pair(code: "ABCD-EFGH", at: target, deviceName: "Test iPhone")
            }
        }
        let session = try await service.restoreSession()
        XCTAssertNil(session)
    }

    func testHTTPConsentOnlyAppliesToTheApprovedAddress() async throws {
        let loader = ScriptedConnectionTransport([.serverInfo, .session])
        let service = ConnectionService(transport: loader, store: MemorySessionStore())
        let target = try await service.probe("http://music.local")
        let otherAddress = try ServerAddress("http://other.local")

        await assertError(APIError.insecureTransportConsentRequired) {
            try await service.pair(code: "ABCD-EFGH", at: target, deviceName: "Test iPhone", consentingTo: otherAddress)
        }
        XCTAssertEqual(loader.requests.count, 1)

        let session = try await service.pair(code: "ABCD-EFGH", at: target, deviceName: "Test iPhone", consentingTo: target.address)
        XCTAssertTrue(session.allowsInsecureHTTP)
        XCTAssertEqual(loader.requests.last?.url?.scheme, "http")
    }

    func testSessionVerificationKeepsTokenThroughProxyFailureAndClearsRevocation() async throws {
        let loader = ScriptedConnectionTransport([
            .serverInfo, .session,
            .serverInfo, .init(status: 403),
            .serverInfo, .init(),
            .serverInfo, .init(body: #"{"signed_in":true,"via":"device"}"#),
            .serverInfo, .init(status: 401)
        ])
        let service = ConnectionService(transport: loader, store: MemorySessionStore())
        let target = try await service.probe("music.local")
        let session = try await service.pair(code: "ABCD-EFGH", at: target, deviceName: "Test iPhone")

        await assertError(APIError.httpStatus(403, retryAfter: nil)) { try await service.verifySession() }
        await assertError(APIError.decodingFailure) { try await service.verifySession() }
        let retained = try await service.restoreSession()
        XCTAssertEqual(retained, session)
        let active = try await service.verifySession()
        XCTAssertEqual(active, .active)
        XCTAssertEqual(loader.requests.last?.url?.path, "/api/auth/status")
        XCTAssertEqual(loader.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(session.token)")

        let revoked = try await service.verifySession()
        XCTAssertEqual(revoked, .revoked)
        let signedOut = try await service.verifySession()
        XCTAssertEqual(signedOut, .signedOut)
    }

    func testSessionVerificationSendsNoTokenToADifferentServer() async throws {
        let loader = ScriptedConnectionTransport([
            .serverInfo, .session, .init(body: #"{"product":"Downtify","server_id":"new-id","api_version":1}"#)
        ])
        let service = ConnectionService(transport: loader, store: MemorySessionStore())
        let target = try await service.probe("music.local")
        let session = try await service.pair(code: "ABCD-EFGH", at: target, deviceName: "Test iPhone")

        await assertError(ConnectionError.differentServer) { try await service.verifySession() }
        XCTAssertEqual(loader.requests.last?.url?.path, "/api/server/info")
        XCTAssertNil(loader.requests.last?.value(forHTTPHeaderField: "Authorization"))
        let retained = try await service.restoreSession()
        XCTAssertEqual(retained, session)
    }

    func testBonjourAdvertisementNormalizesAddressAndFiltersNewerAPI() throws {
        let server = try XCTUnwrap(DiscoveredServer(serviceName: "Server", host: "music.local.", resolvedPort: 8000,
            text: ["name": "Music", "id": "server-id", "api": "1", "scheme": "https", "port": "8443", "path": "/app/"]))
        XCTAssertEqual(server.name, "Music")
        XCTAssertEqual(server.serverID, "server-id")
        XCTAssertEqual(server.address.baseURL.absoluteString, "https://music.local:8443/app")
        XCTAssertNil(DiscoveredServer(serviceName: "Server", host: "music.local", resolvedPort: 8000, text: ["api": "2"]))
    }

    private func body(of request: URLRequest?) throws -> [String: String] {
        let data = try XCTUnwrap(request?.httpBody)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func assertError<Expected: Error & Equatable, Value>(
        _ expected: Expected, file: StaticString = #filePath, line: UInt = #line,
        operation: () async throws -> Value
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? Expected, expected, file: file, line: line)
        }
    }
}

private final class MemorySessionStore: DeviceSessionStoring {
    private var session: DeviceSession?

    func load() throws -> DeviceSession? { session }
    func save(_ session: DeviceSession) throws { self.session = session }
    func clear() throws { session = nil }
}

private final class ScriptedConnectionTransport: HTTPDataLoading {
    struct Response {
        var status = 200
        var body = "{}"
        var headers: [String: String] = [:]

        static let serverInfo = Response(body: #"{"product":"Downtify","server_id":"server-id","name":"Checked server name","api_version":1,"capabilities":{"password_sign_in":true}}"#)
        static let session = Response(body: #"{"token":"test-token","device":{"id":"device-id"},"server":{"server_id":"server-id","name":"Auth server name"},"user":{"username":"maria","role":"user"}}"#)
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw APIError.invalidResponse }
        let next = responses.removeFirst()
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: next.headers))
        return (Data(next.body.utf8), response)
    }
}
