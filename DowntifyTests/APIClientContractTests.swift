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

    func testCatalogSongPreservesProviderPayloadWithoutConflatingIdentifiers() throws {
        let json = #"{"source":"deezer","song_id":"deezer-55","youtube_id":"yt-abc","name":"Roads","artists":["Portishead"],"album_name":"Dummy","duration":305,"url":"https://deezer.test/track/55","preview_url":"https://preview.test/55.mp3","provider_extra":{"rank":1}}"#
        let song = try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))

        XCTAssertEqual(song.source, "deezer")
        XCTAssertEqual(song.songID, "deezer-55")
        XCTAssertEqual(song.youtubeID, "yt-abc")
        XCTAssertNotEqual(song.songID, song.youtubeID)
        XCTAssertEqual(song.id, CatalogResultID(source: "deezer", value: "deezer-55"))
        XCTAssertEqual(song.duration, 305)

        let encoded = try JSONEncoder().encode(song)
        let roundTrip = try JSONDecoder().decode(CatalogSong.self, from: encoded)
        XCTAssertEqual(roundTrip.rawPayload, song.rawPayload)
        XCTAssertEqual(roundTrip.rawPayload.objectValue?["provider_extra"], .object(["rank": .number(1)]))
    }

    func testCatalogTextSearchCanOmitVideoIdentity() throws {
        let json = #"{"source":"text_search","song_id":"search-abc","name":"Roads","artists":["Portishead"],"duration":0,"url":"downtify-search:search-abc"}"#
        let song = try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))

        XCTAssertEqual(song.songID, "search-abc")
        XCTAssertNil(song.youtubeID)
        XCTAssertNil(song.previewURL)
    }

    func testLibraryCatalogRowsResolveOnlyByExactFileWithinProvidedSnapshot() throws {
        let json = #"{"source":"library","song_id":"library:Music/Roads.flac","name":"Roads","artists":["Portishead"],"file":"Music/Roads.flac","url":"","cover_url":"/cover?file=Music%2FRoads.flac"}"#
        let song = try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
        let matching = testLibraryTrack(id: "track-1", file: "Music/Roads.flac")
        let sameTitleOtherFile = testLibraryTrack(id: "track-2", file: "Other/Roads.flac")

        XCTAssertEqual(song.libraryTrack(in: [matching, sameTitleOtherFile])?.id, "track-1")
        XCTAssertNil(song.libraryTrack(in: [sameTitleOtherFile]))
        XCTAssertNil(song.libraryTrack(in: [matching, testLibraryTrack(id: "duplicate", file: "Music/Roads.flac")]))
    }

    func testCatalogSongRejectsMissingSourceOrTitle() {
        let malformed = [#"{"source":"youtube","song_id":"v1"}"#, #"{"name":"Roads","song_id":"v1"}"#]
        for json in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8)))
        }
    }

    func testURLResolutionUsesFixedEnvelopeAndCatalogDTOs() throws {
        let json = #"{"kind":"album","name":"Dummy","subtitle":"Portishead","cover_url":"https://cover.test/dummy.jpg","year":"1994","tracks":[{"source":"youtube","song_id":"v1","name":"Roads"}],"albums":[]}"#
        let resolution = try JSONDecoder().decode(URLResolution.self, from: Data(json.utf8))

        XCTAssertEqual(resolution.kind, "album")
        XCTAssertEqual(resolution.name, "Dummy")
        XCTAssertEqual(resolution.tracks.first?.songID, "v1")
        XCTAssertTrue(resolution.albums.isEmpty)
    }

    func testDiscoverRecommendationsDecodeCurrentDeezerShape() throws {
        let json = #"{"artists":[{"name":"Stereolab","deezer_id":"733","picture_url":"https://cover.test/stereolab.jpg","fans":12,"score":1.25,"because":["Stereolab"]}],"seeds":["Portishead"],"partial":true}"#
        let discover = try JSONDecoder().decode(CatalogDiscoverResults.self, from: Data(json.utf8))

        XCTAssertTrue(discover.partial)
        XCTAssertEqual(discover.artists.first?.source, "deezer")
        XCTAssertEqual(discover.artists.first?.artistID, "733")
        XCTAssertEqual(discover.artists.first?.deezerID, "733")
        XCTAssertEqual(discover.artists.first?.coverURL, "https://cover.test/stereolab.jpg")
        XCTAssertEqual(discover.artists.first?.rawPayload.objectValue?["score"], .number(1.25))
    }

    func testCollectionRowsPreserveDeezerAndSpotifyIDsWhenSourceIsOmitted() throws {
        let json = #"{"albums":[{"name":"Dummy","artist":"Portishead","year":"1994","cover_url":"https://cover.test/dummy.jpg","source":"deezer","deezer_album_id":"13","deezer_artist_id":"42","url":"https://www.deezer.com/album/13","reason":"similar","because":["Air"]},{"name":"Third","artist":"Portishead","year":"2008","cover_url":"https://cover.test/third.jpg","spotify_id":"sp-album-1","url":"https://open.spotify.com/album/sp-album-1","reason":"more_from","because":["Portishead"]}],"more_albums":[],"playlists":[{"name":"This Is Portishead","owner":"spotify","cover_url":"https://cover.test/list.jpg","spotify_id":"sp-playlist-1","url":"https://open.spotify.com/playlist/sp-playlist-1","reason":"this_is","artist":"Portishead"}],"partial":false}"#
        let collections = try JSONDecoder().decode(CatalogCollectionsResults.self, from: Data(json.utf8))

        XCTAssertEqual(collections.albums[0].source, "deezer")
        XCTAssertEqual(collections.albums[0].deezerAlbumID, "13")
        XCTAssertEqual(collections.albums[1].source, "spotify")
        XCTAssertEqual(collections.albums[1].spotifyID, "sp-album-1")
        XCTAssertEqual(collections.playlists.first?.source, "spotify")
        XCTAssertEqual(collections.playlists.first?.spotifyID, "sp-playlist-1")
    }
    func testPlaylistMutationEndpointsUseAuthenticatedV1Contract() async throws {
        let info = #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#
        let canonical = #"{"name":"Night","manual":true,"count":2,"track_ids":["a","a"]}"#
        let loader = SequenceLoader(bodies: [info, canonical, info, canonical, info, canonical, info, canonical])
        let session = playlistMutationSession()
        let api = LibraryCollectionsAPI(transport: loader)

        try await api.createPlaylist(name: "Night", session: session)
        try await api.renamePlaylist(name: "Old", to: "Night", session: session)
        try await api.editPlaylistTracks(
            name: "Night", add: ["a", "a"], remove: ["b"],
            removeEntries: [.init(trackID: "a", occurrence: 1)], allowDuplicates: true, session: session
        )
        try await api.reorderPlaylist(name: "Night", trackIDs: ["a", "a"], session: session)

        let writes = loader.requests.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertEqual(writes.map(\.httpMethod), ["POST", "POST", "POST", "PUT"])
        XCTAssertEqual(writes.compactMap { $0.url?.path }, [
            "/music/api/v1/playlists",
            "/music/api/v1/playlists/rename",
            "/music/api/v1/playlists/tracks",
            "/music/api/v1/playlists/order"
        ])
        XCTAssertTrue(writes.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        XCTAssertEqual(try jsonObject(of: writes[0]) as? [String: String], ["name": "Night"])
        XCTAssertEqual(try jsonObject(of: writes[1]) as? [String: String], ["name": "Old", "new_name": "Night"])

        let edit = try XCTUnwrap(try jsonObject(of: writes[2]) as? [String: Any])
        XCTAssertEqual(edit["name"] as? String, "Night")
        XCTAssertEqual(edit["add"] as? [String], ["a", "a"])
        XCTAssertEqual(edit["remove"] as? [String], ["b"])
        XCTAssertEqual(edit["allow_duplicates"] as? Bool, true)
        let removeEntries = try XCTUnwrap(edit["remove_entries"] as? [[String: Any]])
        XCTAssertEqual(removeEntries.count, 1)
        XCTAssertEqual(removeEntries[0]["track_id"] as? String, "a")
        XCTAssertEqual(removeEntries[0]["occurrence"] as? Int, 1)

        let order = try XCTUnwrap(try jsonObject(of: writes[3]) as? [String: Any])
        XCTAssertEqual(order["name"] as? String, "Night")
        XCTAssertEqual(order["track_ids"] as? [String], ["a", "a"])
    }

    func testPlaylistMutationResponsePreservesDuplicateIDsAndOptionalFields() throws {
        let response = try JSONDecoder().decode(
            PlaylistMutationResponseDTO.self,
            from: Data(#"{"name":"Night","manual":true,"count":3,"track_ids":["a","a","b"],"previous":"Old","added":2,"removed":1,"already":["b","b"]}"#.utf8)
        )

        XCTAssertEqual(response.name, "Night")
        XCTAssertTrue(response.manual)
        XCTAssertEqual(response.count, 3)
        XCTAssertEqual(response.trackIDs, ["a", "a", "b"])
        XCTAssertEqual(response.previous, "Old")
        XCTAssertEqual(response.added, 2)
        XCTAssertEqual(response.removed, 1)
        XCTAssertEqual(response.already, ["b", "b"])

        let minimal = try JSONDecoder().decode(
            PlaylistMutationResponseDTO.self,
            from: Data(#"{"name":"Empty","manual":true,"count":0,"track_ids":[]}"#.utf8)
        )
        XCTAssertNil(minimal.previous)
        XCTAssertNil(minimal.added)
        XCTAssertNil(minimal.removed)
        XCTAssertNil(minimal.already)
    }

    func testPlaylistMutationRejectsRequestsAboveServerLimitsBeforeSending() async throws {
        let loader = SequenceLoader(bodies: [])
        let session = playlistMutationSession()
        let api = LibraryCollectionsAPI(transport: loader)
        let tooMany = Array(repeating: "track", count: 10_001)

        do {
            try await api.editPlaylistTracks(name: "Night", add: tooMany, session: session)
            XCTFail("Expected the track edit limit to be enforced")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(400, retryAfter: nil))
        }
        do {
            try await api.reorderPlaylist(name: "Night", trackIDs: tooMany, session: session)
            XCTFail("Expected the reorder limit to be enforced")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(400, retryAfter: nil))
        }
        XCTAssertTrue(loader.requests.isEmpty)
    }

    func testPlaylistMutationPropagatesHTTPConflict() async throws {
        let info = #"{"product":"Downtify","api_version":1,"server_id":"srv"}"#
        let loader = SequenceLoader(bodies: [info, #"{"detail":"stale order"}"#], statuses: [200, 409])
        do {
            try await LibraryCollectionsAPI(transport: loader)
                .reorderPlaylist(name: "Night", trackIDs: ["a", "a"], session: playlistMutationSession())
            XCTFail("Expected HTTP conflict")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(409, retryAfter: nil))
        }
        XCTAssertEqual(loader.requests.last?.url?.path, "/music/api/v1/playlists/order")
    }

    private func playlistMutationSession() -> DeviceSession {
        DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Music",
                      deviceID: "device", username: "alice", role: "user", token: "secret", allowsInsecureHTTP: false)
    }

    private func jsonObject(of request: URLRequest) throws -> Any {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody), options: [.fragmentsAllowed])
    }
}


private func testLibraryTrack(id: String, file: String) -> LibraryTrack {
    LibraryTrack(id: id, file: file, title: "Roads", artist: "Portishead", artists: ["Portishead"], album: "Dummy",
                 albumArtist: "Portishead", albumID: "album", artistID: "artist", trackNumber: 1, year: "1994",
                 duration: 305, codec: "flac", bitrate: 900_000, sampleRate: 44_100, channels: 2,
                 size: 10_000, added: 0, hasCover: true, isExplicit: false, playlists: [])
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
import Foundation
import XCTest
@testable import Downtify

final class ServerDownloadQueueTests: XCTestCase {
    func testCatalogTrackRequestSendsCompleteProviderPayloadAndPseudoURL() async throws {
        let loader = QueueContractLoader(responses: [serverInfo, #""job-1""#])
        let session = makeSession()
        let song = try decodeSong(#"{"source":"text_search","song_id":"search-42","name":"Roads","artists":["Portishead"],"track_number":3,"duration":305,"url":"downtify-search:search-42","download_by_metadata":true,"provider_extra":{"rank":7}}"#)

        let id = try await ServerDownloadQueue(transport: loader).requestTrack(song: song, session: session)

        XCTAssertEqual(id, "job-1")
        let request = try XCTUnwrap(loader.requests.last)
        XCTAssertEqual(request.url?.path, "/music/api/download/url")
        let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(queryItems.first(where: { $0.name == "url" })?.value, "downtify-search:search-42")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "text_search")
        XCTAssertEqual(json["song_id"] as? String, "search-42")
        XCTAssertEqual(json["url"] as? String, "downtify-search:search-42")
        XCTAssertEqual(json["track_number"] as? Int, 3)
        XCTAssertEqual(json["download_by_metadata"] as? Bool, true)
        XCTAssertEqual((json["provider_extra"] as? [String: Any])?["rank"] as? Int, 7)
    }

    func testBatchRequestEncodesOptionsAndRawCatalogSongs() async throws {
        let loader = QueueContractLoader(responses: [serverInfo, #"{"job_ids":["job-1","job-2"],"count":2}"#])
        let songs = [
            try decodeSong(#"{"source":"deezer","song_id":"dz-1","youtube_id":"yt-1","name":"One","artists":["A"],"url":"https://deezer.test/1","deezer_artist_id":"artist-1"}"#),
            try decodeSong(#"{"source":"youtube","song_id":"yt-2","name":"Two","artists":["B"],"url":"https://music.youtube.com/watch?v=yt-2"}"#)
        ]
        let options = ServerDownloadQueue.BatchOptions(playlistURL: "https://playlist.test/1", playlistName: "Set", coverURL: "https://img.test/1", generateM3U: true)

        let response = try await ServerDownloadQueue(transport: loader).requestBatch(songs: songs, options: options, session: makeSession())

        XCTAssertEqual(response, .init(jobIDs: ["job-1", "job-2"], count: 2))
        let request = try XCTUnwrap(loader.requests.last)
        XCTAssertEqual(request.url?.path, "/music/api/download/batch")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["playlist_url"] as? String, options.playlistURL)
        XCTAssertEqual(json["playlist_name"] as? String, options.playlistName)
        XCTAssertEqual(json["cover_url"] as? String, options.coverURL)
        XCTAssertEqual(json["generate_m3u"] as? Bool, true)
        let sentSongs = try XCTUnwrap(json["songs"] as? [[String: Any]])
        XCTAssertEqual(sentSongs.count, 2)
        XCTAssertEqual(sentSongs[0]["youtube_id"] as? String, "yt-1")
        XCTAssertEqual(sentSongs[0]["deezer_artist_id"] as? String, "artist-1")
    }

    func testAlbumRequestRequiresSupportedYouTubeMusicFormAndEncodesURL() async throws {
        let loader = QueueContractLoader(responses: [serverInfo, #"{"yt-1":"queued"}"#])
        let url = "https://music.youtube.com/browse/MPREb_abc-123"

        let response = try await ServerDownloadQueue(transport: loader).requestAlbum(url: url, session: makeSession())

        XCTAssertEqual(response, ["yt-1": "queued"])
        let request = try XCTUnwrap(loader.requests.last)
        XCTAssertEqual(request.url?.path, "/music/api/download/album")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, url)
        XCTAssertFalse(ServerDownloadQueue.isYouTubeMusicAlbumURL("https://music.youtube.com/watch?v=abc"))
    }

    func testCancellationDuringServerInfoDoesNotSendDownloadMutation() async throws {
        let loader = DelayedServerInfoLoader(body: serverInfo)
        let song = try decodeSong(#"{"source":"youtube","song_id":"yt-1","name":"One","artists":["A"],"url":"https://music.youtube.com/watch?v=yt-1"}"#)
        let task = Task { try await ServerDownloadQueue(transport: loader).requestTrack(song: song, session: makeSession()) }

        await fulfillment(of: [loader.started], timeout: 2)
        task.cancel()
        loader.finishServerInfo()

        do {
            _ = try await task.value
            XCTFail("Cancelled request unexpectedly succeeded")
        } catch is CancellationError {
            XCTAssertEqual(loader.requests.count, 1)
            XCTAssertEqual(loader.requests.first?.url?.path, "/music/api/server/info")
        }
    }

    @MainActor
    func testAlbumOutcomeRequiresKnownCompleteTrackList() throws {
        let first = try decodeSong(#"{"source":"youtube","song_id":"song-1","youtube_id":"yt-1","name":"One"}"#)
        let second = try decodeSong(#"{"source":"youtube","song_id":"song-2","youtube_id":"yt-2","name":"Two"}"#)
        let expected = [first, second]

        XCTAssertEqual(ServerDownloadPresentationModel.albumOutcome(response: [:], expected: nil), .outcomeUnknown)
        XCTAssertEqual(ServerDownloadPresentationModel.albumOutcome(response: [:], expected: []), .outcomeUnknown)
        XCTAssertEqual(ServerDownloadPresentationModel.albumOutcome(response: [:], expected: expected),
                       .partiallyAccepted(successful: 0, expected: 2))
        XCTAssertEqual(ServerDownloadPresentationModel.albumOutcome(response: ["yt-1": "queued"], expected: expected),
                       .partiallyAccepted(successful: 1, expected: 2))
        XCTAssertEqual(ServerDownloadPresentationModel.albumOutcome(response: ["yt-1": "queued", "yt-2": "queued"], expected: expected),
                       .accepted)
    }

    func testQueueJobsDecodeCurrentAndLegacySongFields() throws {
        let data = Data(#"[{"song":{"song_id":"new-id","name":"Current","artists":["A","B"]},"status":"running","progress":0.5},{"song":{"id":"old-id","title":"Legacy","artist":"C"},"status":"done"}]"#.utf8)

        let jobs = try JSONDecoder().decode([ServerDownloadQueue.Job].self, from: data)

        XCTAssertEqual(jobs.map(\.id), ["new-id", "old-id"])
        XCTAssertEqual(jobs[0].song.title, "Current")
        XCTAssertEqual(jobs[0].song.artist, "A, B")
        XCTAssertEqual(jobs[1].song.title, "Legacy")
        XCTAssertEqual(jobs[1].song.artists, [])
    }

    private var serverInfo: String { #"{"product":"Downtify","api_version":1,"server_id":"server"}"# }

    private func makeSession() -> DeviceSession {
        DeviceSession(baseAddress: "https://example.test/music", serverID: "server", serverName: "Music",
                      deviceID: "device", username: nil, role: nil, token: "token", allowsInsecureHTTP: false)
    }

    private func decodeSong(_ json: String) throws -> CatalogSong {
        try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
    }
}

private final class QueueContractLoader: HTTPDataLoading {
    private var responses: [String]
    private(set) var requests: [URLRequest] = []

    init(responses: [String]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw APIError.invalidResponse }
        let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(responses.removeFirst().utf8), response)
    }
}

private final class DelayedServerInfoLoader: HTTPDataLoading {
    let started = XCTestExpectation(description: "server-info request started")
    private let body: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []

    init(body: String) { self.body = body }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if requests.count == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func finishServerInfo() { continuation?.resume() }
}
