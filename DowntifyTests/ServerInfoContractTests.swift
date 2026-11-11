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

    func testCatalogSearchVerifiesServerAndEncodesUnicodeQuery() async throws {
        let loader = CatalogSequenceLoader(bodies: [
            #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#,
            #"[{"source":"youtube_music","song_id":"song-1","youtube_id":"video-1","name":"Roads","artist":"Portishead","artists":["Portishead"],"url":"https://music.youtube.com/watch?v=video-1"}]"#
        ])
        let session = catalogSession()

        let songs = try await CatalogAPI(transport: loader).searchSongs(query: "Björk & Co", session: session)

        XCTAssertEqual(songs.map(\.title), ["Roads"])
        XCTAssertEqual(loader.requests.count, 2)
        XCTAssertEqual(loader.requests[0].url?.path, "/music/api/server/info")
        XCTAssertNil(loader.requests[0].value(forHTTPHeaderField: "Authorization"))
        let request = try XCTUnwrap(loader.requests.last)
        XCTAssertEqual(request.url?.path, "/music/api/songs/search")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "query", value: "Björk & Co")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testCatalogRefusesMismatchedServerBeforeSendingBearerToken() async throws {
        let loader = CatalogSequenceLoader(bodies: [
            #"{"product":"Downtify","api_version":1,"server_id":"other"}"#
        ])

        do {
            _ = try await CatalogAPI(transport: loader).searchSongs(query: "Air", session: catalogSession())
            XCTFail("Expected server identity mismatch")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .differentServer)
        }
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertNil(loader.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testLibraryOnlyAllowsLocalSearchButBlocksExternalResolutionBeforeRequest() async throws {
        let info = #"{"product":"Downtify","api_version":1,"server_id":"srv","library_only":true}"#
        let row = #"{"source":"library","song_id":"library:Artist - Roads.flac","file":"Artist - Roads.flac","name":"Roads","artist":"Portishead","artists":["Portishead"],"url":""}"#
        let loader = CatalogSequenceLoader(bodies: [info, "[\(row)]", info])
        let api = CatalogAPI(transport: loader)
        let session = catalogSession()

        let results = try await api.searchSongs(query: "Roads", session: session)
        XCTAssertEqual(results.first?.source, "library")
        XCTAssertEqual(results.first?.songID, "library:Artist - Roads.flac")
        XCTAssertEqual(results.first?.file, "Artist - Roads.flac")
        do {
            _ = try await api.resolve(url: "https://open.spotify.com/track/example", session: session)
            XCTFail("Expected external resolution to be unavailable in library-only mode")
        } catch let error as CatalogAPIError {
            XCTAssertEqual(error, .libraryOnly)
        }
        XCTAssertEqual(loader.requests.count, 3)
        XCTAssertEqual(loader.requests.map { $0.url?.path }, [
            "/music/api/server/info", "/music/api/songs/search", "/music/api/server/info"
        ])
    }

    func testCatalogPreservesServerAuthorizationAndUpstreamErrors() async throws {
        for status in [403, 502] {
            let loader = CatalogSequenceLoader(
                bodies: [#"{"product":"Downtify","api_version":1,"server_id":"srv"}"#, #"{"detail":"failed"}"#],
                statuses: [200, status]
            )
            do {
                _ = try await CatalogAPI(transport: loader).searchSongs(query: "Air", session: catalogSession())
                XCTFail("Expected HTTP \(status)")
            } catch let error as APIError {
                XCTAssertEqual(error, .httpStatus(status, retryAfter: nil))
            }
            XCTAssertEqual(loader.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        }
    }

    func testDiscoverUsesTypedLibrarySummaryRequestBody() async throws {
        let loader = CatalogSequenceLoader(bodies: [
            #"{"product":"Downtify","api_version":1,"server_id":"srv","capabilities":{"discover":true}}"#,
            #"{"artists":[],"seeds":[],"partial":false}"#
        ])
        let input = [CatalogLibraryArtist(name: "Portishead", tracks: 6, liked: 2)]

        _ = try await CatalogAPI(transport: loader).discover(library: input, session: catalogSession())

        let request = try XCTUnwrap(loader.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/music/api/discover")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        let artists = try XCTUnwrap(json?["library"] as? [[String: Any]])
        XCTAssertEqual(artists.first?["name"] as? String, "Portishead")
        XCTAssertEqual(artists.first?["tracks"] as? Int, 6)
        XCTAssertEqual(artists.first?["liked"] as? Int, 2)
    }

    func testCollectionRequestsRespectLibraryOnlyPolicy() async throws {
        for libraryOnly in [true, false] {
            let info = """
            {"product":"Downtify","api_version":1,"server_id":"srv","library_only":\(libraryOnly),"capabilities":{"discover":true}}
            """
            let response = #"{"albums":[],"more_albums":[],"playlists":[],"partial":false}"#
            for spotify in [false, true] {
                let loader = CatalogSequenceLoader(bodies: libraryOnly ? [info] : [info, response])
                let api = CatalogAPI(transport: loader)
                do {
                    if spotify {
                        _ = try await api.spotifyCollections(library: [], albums: [], playlistIDs: [], shown: [], session: catalogSession())
                    } else {
                        _ = try await api.deezerCollections(library: [], albums: [], playlistNames: [], session: catalogSession())
                    }
                    XCTAssertFalse(libraryOnly)
                } catch let error as CatalogAPIError {
                    XCTAssertTrue(libraryOnly)
                    XCTAssertEqual(error, .libraryOnly)
                }
                XCTAssertEqual(loader.requests.count, libraryOnly ? 1 : 2)
            }
        }
    }

    private func catalogSession() -> DeviceSession {
        DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Music",
                      deviceID: "phone", username: "alice", role: "user", token: "secret",
                      allowsInsecureHTTP: false)
    }

    private func decode(_ fixture: String) throws -> MobileAPIV1.ServerInfoDTO {
        try JSONDecoder().decode(MobileAPIV1.ServerInfoDTO.self, from: Data(fixture.utf8))
    }
}

private final class CatalogSequenceLoader: HTTPDataLoading {
    private var bodies: [String]
    private var statuses: [Int]
    private(set) var requests: [URLRequest] = []

    init(bodies: [String], statuses: [Int]? = nil) {
        self.bodies = bodies
        self.statuses = statuses ?? Array(repeating: 200, count: bodies.count)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !bodies.isEmpty, !statuses.isEmpty else { throw APIError.invalidResponse }
        let status = statuses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(bodies.removeFirst().utf8), response)
    }
}
