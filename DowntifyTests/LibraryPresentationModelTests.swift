import XCTest
@testable import Downtify

@MainActor
final class LibraryPresentationModelTests: XCTestCase {
    func testLibraryOrderingAndSearchCoverTitleArtistAndAlbum() {
        let tracks = [
            makeTrack("z", title: "Zebra", artist: "Ada", album: "Night Songs"),
            makeTrack("b", title: "Blue", artist: "Zed", album: "First Light"),
            makeTrack("a", title: "Blue", artist: "Ada", album: "Second Light")
        ]

        let sorted = LibraryTrackOrdering.sorted(tracks)
        XCTAssertEqual(sorted.map(\.id), ["a", "b", "z"])
        XCTAssertEqual(LibraryTrackOrdering.matching(sorted, query: "  blue ").map(\.id), ["a", "b"])
        XCTAssertEqual(LibraryTrackOrdering.matching(sorted, query: "zed").map(\.id), ["b"])
        XCTAssertEqual(LibraryTrackOrdering.matching(sorted, query: "night songs").map(\.id), ["z"])
        XCTAssertTrue(LibraryTrackOrdering.matching(sorted, query: "missing").isEmpty)
        XCTAssertEqual(LibraryTrackOrdering.matching(sorted, query: " "), sorted)
    }

    func testCatalogSearchDiscardsLateResultForAnOlderQuery() async throws {
        let session = makeSession()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let gate = CatalogPresentationTestGate()
        let api = CatalogServingStub(libraryOnly: false, gate: gate)
        let model = CatalogPresentationModel(api: api, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.policyState == .ready }

        model.search("old")
        await gate.waitUntilStarted()
        model.search("new")
        await waitUntil {
            if case .loaded(let songs) = model.searchSongsState { return songs.first?.title == "new" }
            return false
        }
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        if case .loaded(let songs) = model.searchSongsState {
            XCTAssertEqual(songs.map(\.title), ["new"])
        } else {
            XCTFail("Expected the latest query results to remain visible")
        }
        continuation.finish()
    }

    func testCatalogSearchDiscardsLateResultAfterAccountChange() async throws {
        let first = makeSession(server: "first")
        let second = makeSession(server: "second")
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let gate = CatalogPresentationTestGate()
        let model = CatalogPresentationModel(api: CatalogServingStub(libraryOnly: false, gate: gate),
                                             sessionUpdates: { updates })
        model.start()
        continuation.yield(first)
        await waitUntil { model.policyState == .ready }
        model.search("old")
        await gate.waitUntilStarted()

        continuation.yield(second)
        await waitUntil { model.session == second && model.policyState == .ready }
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.session, second)
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertEqual(model.searchSongsState, .idle)
        continuation.finish()
    }

    func testLibraryOnlyPolicyKeepsLocalSearchAndDisablesExternalFinderDetails() async throws {
        let session = makeSession()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let api = CatalogServingStub(libraryOnly: true)
        let model = CatalogPresentationModel(api: api, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.policyState == .ready }

        XCTAssertTrue(model.isLibraryOnly == true)
        XCTAssertFalse(model.externalCatalogAvailable)
        model.search("Roads")
        await waitUntil {
            if case .loaded(let songs) = model.searchSongsState { return songs.first?.source == "library" }
            return false
        }
        model.loadFinderArtist(id: "123")
        if case .unavailable = model.finderArtistState {
            // Provider details are disabled while local library results remain usable.
        } else {
            XCTFail("Expected provider Finder details to be unavailable")
        }
        continuation.finish()
    }

    func testPolicyRefreshClearsExternalSearchThenAllowsLocalResults() async throws {
        let session = makeSession()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let policy = CatalogPolicyBox(libraryOnly: false)
        let model = CatalogPresentationModel(api: CatalogServingStub(policy: policy), sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.policyState == .ready }
        model.search("Roads")
        await waitUntil {
            if case .loaded(let songs) = model.searchSongsState { return songs.first?.source == "youtube" }
            return false
        }

        await policy.setLibraryOnly(true)
        await model.refreshPolicy(for: session)
        XCTAssertTrue(model.isLibraryOnly == true)
        XCTAssertEqual(model.searchSongsState, .idle)
        XCTAssertEqual(model.searchQuery, "Roads")

        model.search("Roads")
        await waitUntil {
            if case .loaded(let songs) = model.searchSongsState { return songs.first?.source == "library" }
            return false
        }
        continuation.finish()
    }

    func testDiscoverSectionsKeepPartialSuccessWhenAnotherProviderFails() async throws {
        let session = makeSession()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let api = CatalogServingStub(libraryOnly: false, discoverPartial: true, spotifyFails: true)
        let model = CatalogPresentationModel(api: api, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.policyState == .ready }

        model.loadDiscover(library: [], albums: [], playlistNames: [], playlistIDs: [], shown: [])
        await waitUntil {
            if case .partial = model.discoverArtistsState,
               case .partial = model.deezerCollectionsState,
               case .failed = model.spotifyCollectionsState { return true }
            return false
        }
        if case .partial = model.discoverArtistsState {} else { XCTFail("Expected partial artist results") }
        if case .partial = model.deezerCollectionsState {} else { XCTFail("Expected the successful partial provider section") }
        if case .failed = model.spotifyCollectionsState {} else { XCTFail("Expected only the failed provider section to fail") }
        continuation.finish()
    }

    func testLoadsCachedTracksBeforeReportingRefreshFailure() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let seed = LibraryRepository(database: database, feed: Feed([.page(1, full: true, tracks: [makeTrack("cached")])]), session: { session })
        _ = try await seed.sync()

        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        continuation.yield(session)
        let repo = LibraryRepository(database: database, feed: Feed([.failure]), session: { session })
        let model = LibraryPresentationModel(repository: repo, sessionUpdates: { updates })
        model.start()
        await waitUntil { model.state == .ready }

        XCTAssertEqual(model.tracks.map(\.id), ["cached"])
        model.syncDidFail(for: session, message: "offline")
        XCTAssertEqual(model.state, .cachedError("offline"))
        XCTAssertEqual(model.tracks.map(\.id), ["cached"])
        continuation.finish()
    }

    func testSuccessfulBackgroundSyncClearsCachedError() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let seed = LibraryRepository(
            database: database, feed: Feed([.page(1, full: true, tracks: [makeTrack("cached")])]),
            session: { session }
        )
        _ = try await seed.sync()

        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        continuation.yield(session)
        let model = LibraryPresentationModel(
            repository: LibraryRepository(database: database, feed: Feed([]), session: { session }),
            sessionUpdates: { updates }
        )
        model.start()
        await waitUntil { model.state == .ready }
        model.syncDidFail(for: session, message: "offline")
        XCTAssertEqual(model.state, .cachedError("offline"))

        await model.syncDidUpdate(for: session)

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.tracks.map(\.id), ["cached"])
        continuation.finish()
    }

    func testSessionChangeClearsPriorLibraryAndIgnoresStaleUpdate() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = makeSession(server: "one")
        let second = makeSession(server: "two")
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let sessions = SessionBox()
        let repository = LibraryRepository(
            database: database, feed: Feed([.page(1, full: true, tracks: [])]), session: { await sessions.value }
        )
        let model = LibraryPresentationModel(repository: repository, sessionUpdates: { updates })
        await sessions.set(first)
        _ = try await repository.sync()
        model.start()
        continuation.yield(first)
        await waitUntil { model.state == .empty }
        XCTAssertEqual(model.state, .empty)
        await sessions.set(second)
        continuation.yield(second)
        await waitUntil { model.state == .loading }
        XCTAssertEqual(model.state, .loading)
        _ = try await repository.sync()
        await model.syncDidUpdate(for: second)
        model.syncDidFail(for: first, message: "stale")
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.tracks.isEmpty)
        continuation.finish()
    }

    func testStorageFailureHasDistinctPresentationState() async throws {
        let missingFolder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let session = makeSession()
        let repository = LibraryRepository(
            database: LibraryDatabase(fileURL: missingFolder.appending(path: "library.sqlite")),
            feed: Feed([]), session: { session }
        )
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryPresentationModel(repository: repository, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { if case .storageFailure = model.state { return true }; return false }
        if case .storageFailure = model.state {
            // Storage failures remain distinct from a network refresh failure.
        } else {
            XCTFail("Expected storage failure state")
        }
        continuation.finish()
    }

    func testLargeCatalogUsesStableGroupsAndPreservesPlaylistAndLikeOrder() throws {
        let tracks = (0..<10_000).map {
            makeTrack("id-\($0)", title: "Track \($0)", artist: "Singer", album: "Same Title",
                      albumID: "album-\($0 % 100)", artistID: "artist-\($0 % 10)", added: Int64($0))
        }
        let catalog = LibraryCatalog(tracks)
        XCTAssertEqual(catalog.albumsByID.count, 100)
        XCTAssertEqual(catalog.artistsByID.count, 10)
        XCTAssertEqual(catalog.albums(for: "artist-0").count, 10)
        let newest = LibrarySort.recentlyAdded.ordered(Array(catalog.albumsByID.values), descending: true)
        XCTAssertEqual(newest.first?.id, "album-99")
        let earliest = LibrarySort.recentlyAdded.ordered(Array(catalog.albumsByID.values), descending: false)
        XCTAssertEqual(earliest.first?.id, "album-0")
        XCTAssertEqual(LibrarySort.alphabetical.orderedTracks([tracks[2], tracks[0]], descending: false), [tracks[0], tracks[2]])
        XCTAssertEqual(LibrarySort.artist.orderedTracks([makeTrack("first", artist: "A"), makeTrack("last", artist: "Z")],
                                                        descending: true).map(\.id), ["last", "first"])
        let playlist = try JSONDecoder().decode(LibraryPlaylist.self, from: Data(
            #"{"name":"stable","display_name":"Display","track_ids":["id-2","gone","id-1","id-2"]}"#.utf8
        ))
        XCTAssertEqual(playlist.title, "Display")
        XCTAssertNil(playlist.favorite)
        XCTAssertEqual(catalog.tracks(in: .playlist("stable"), likedIDs: [], playlist: playlist).map(\.id),
                       ["id-2", "id-1", "id-2"])
        XCTAssertEqual(catalog.tracks(in: .liked, likedIDs: ["id-2", "gone", "id-1"], playlist: nil).map(\.id),
                       ["id-2", "id-1"])
        let numbered = LibraryCatalog([makeTrack("z", albumID: "album", trackNumber: 1),
                                       makeTrack("a", albumID: "album", trackNumber: 2)])
        XCTAssertEqual(numbered.tracks(in: .album("album"), likedIDs: [], playlist: nil).map(\.id), ["z", "a"])
    }

    func testOfflineCollectionsRestoreFromAccountCacheAndStayIsolated() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = makeSession(server: "one")
        let second = makeSession(server: "two")
        let scope = LibraryScope(serverID: first.serverID, username: first.username, deviceID: first.deviceID)
        let saved = Data(#"[{"name":"stable","display_name":"Display","favorite":true,"track_ids":["cached"]}]"#.utf8)
        try await database.saveBrowseData(saved, key: "playlists", in: scope)
        try await database.saveBrowseData(JSONEncoder().encode(["cached"]), key: "likes", in: scope)
        try await database.saveBrowseData(JSONEncoder().encode([LibraryContext.album("album")]), key: "recents", in: scope)

        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: CollectionsFeed(), database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(first)
        await waitUntil { model.playlistState == .unavailable }
        XCTAssertEqual(model.playlists?.first?.title, "Display")
        XCTAssertEqual(model.likedIDs, ["cached"])
        XCTAssertEqual(model.recents, [.album("album")])

        await model.toggleLike(makeTrack("cached"))
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.likedIDs, ["cached"])

        continuation.yield(second)
        await waitUntil { model.playlistState == .unavailable && model.playlists == nil }
        XCTAssertNil(model.likedIDs)
        XCTAssertTrue(model.recents.isEmpty)
        continuation.finish()
    }

    func testLikesAndFavoriteMutationsUseStableIdentifiersAndRetainAuthoritativeOrder() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = CollectionsHTTP()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: LibraryCollectionsAPI(transport: transport), database: database,
                                            sessionUpdates: { updates })
        model.start()
        continuation.yield(makeSession())
        await waitUntil { model.playlistState == .ready && model.likesState == .ready }
        XCTAssertEqual(model.playlist(named: "stable")?.title, "Display label")
        await model.toggleFavorite("legacy")
        await model.toggleFavorite("stable")
        await model.toggleLike(makeTrack("song"))
        XCTAssertEqual(model.playlist(named: "stable")?.favorite, true)
        XCTAssertEqual(model.likedIDs, ["song", "prior"])
        await model.toggleLike(makeTrack("song"))
        XCTAssertEqual(model.likedIDs, ["prior"])
        let writes = await transport.writes
        XCTAssertEqual(writes, ["favorite:stable:true", "like:song:true", "like:song:false"])
        continuation.finish()
    }

    private func makeDatabase() throws -> (LibraryDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (LibraryDatabase(fileURL: folder.appending(path: "library.sqlite")), folder)
    }

    private func makeSession(server: String = "server") -> DeviceSession {
        DeviceSession(baseAddress: "https://example.test", serverID: server, serverName: "Server", deviceID: "device",
                      username: "listener", role: nil, token: "secret", allowsInsecureHTTP: false)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }
}

private struct Feed: LibraryFeedFetching {
    enum Result { case page(Int64, full: Bool, tracks: [LibraryTrack]); case failure }
    var results: [Result]
    init(_ results: [Result]) { self.results = results }

    func fetch(since cursor: Int64, etag: String?, refresh: Bool, session: DeviceSession) async throws -> LibraryFeedResult {
        guard !results.isEmpty else { return .unchanged }
        switch results[0] {
        case let .page(cursor, full, tracks):
            return .page(LibraryPage(cursor: cursor, full: full, tracks: tracks, deleted: []), etag: nil)
        case .failure: throw APIError.transportFailure
        }
    }
}

private actor SessionBox {
    private(set) var value: DeviceSession?
    func set(_ session: DeviceSession?) { value = session }
}

private func makeTrack(_ id: String, title: String? = nil, artist: String = "", album: String = "",
                       albumID: String = "", artistID: String = "", trackNumber: Int = 0, added: Int64 = 0) -> LibraryTrack {
    LibraryTrack(id: id, file: "\(id).mp3", title: title ?? id, artist: artist, artists: [], album: album, albumArtist: "",
                 albumID: albumID, artistID: artistID, trackNumber: trackNumber, year: "", duration: 0, codec: "mp3", bitrate: 0,
                 sampleRate: 0, channels: 0, size: 0, added: added, hasCover: false, isExplicit: false, playlists: [])
}


private struct CollectionsFeed: LibraryCollectionsFetching {
    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist] { throw APIError.transportFailure }
    func likes(for session: DeviceSession) async throws -> [String] { throw APIError.transportFailure }
    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws { throw APIError.transportFailure }
    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws { throw APIError.transportFailure }
}

private actor CollectionsHTTP: HTTPDataLoading {
    private(set) var writes: [String] = []
    private var favorite = false
    private var liked = false

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let body: String
        if url.path == "/api/server/info" {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            body = #"{"product":"Downtify","api_version":1,"server_id":"server"}"#
        } else {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let data = try XCTUnwrap(request.httpBody)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                switch url.path {
                case "/api/v1/playlists/favorite":
                    let name = try XCTUnwrap(fields["name"] as? String)
                    favorite = try XCTUnwrap(fields["favorite"] as? Bool)
                    writes.append("favorite:\(name):\(favorite)")
                case "/api/v1/likes":
                    let id = try XCTUnwrap(fields["track_id"] as? String)
                    liked = try XCTUnwrap(fields["liked"] as? Bool)
                    writes.append("like:\(id):\(liked)")
                default: XCTFail("Unexpected route: \(url.path)")
                }
                body = "{}"
            } else {
                XCTAssertEqual(request.httpMethod, "GET")
                switch url.path {
                case "/api/v1/playlists":
                    body = #"[{"name":"stable","display_name":"Display label","favorite":\#(favorite),"track_ids":["song"]},{"name":"legacy","track_ids":[]}]"#
                case "/api/v1/likes":
                    body = liked ? #"{"track_ids":["song","prior"]}"# : #"{"track_ids":["prior"]}"#
                default:
                    XCTFail("Unexpected route: \(url.path)")
                    body = ""
                }
            }
        }
        return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private actor CatalogPresentationTestGate {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        hasStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor CatalogPolicyBox {
    private var libraryOnly: Bool

    init(libraryOnly: Bool) { self.libraryOnly = libraryOnly }
    func currentLibraryOnly() -> Bool { libraryOnly }
    func setLibraryOnly(_ value: Bool) { libraryOnly = value }
}

private struct CatalogServingStub: CatalogServing {
    let policy: CatalogPolicyBox
    var discoverPartial = false
    var spotifyFails = false
    var gate: CatalogPresentationTestGate?

    init(libraryOnly: Bool, discoverPartial: Bool = false, spotifyFails: Bool = false,
         gate: CatalogPresentationTestGate? = nil) {
        policy = CatalogPolicyBox(libraryOnly: libraryOnly)
        self.discoverPartial = discoverPartial
        self.spotifyFails = spotifyFails
        self.gate = gate
    }

    init(policy: CatalogPolicyBox) { self.policy = policy }

    func serverInfo(session: DeviceSession) async throws -> MobileAPIV1.ServerInfoDTO {
        let libraryOnly = await policy.currentLibraryOnly()
        let fixture = """
        {"product":"Downtify","api_version":1,"server_id":"\(session.serverID)","library_only":\(libraryOnly),"capabilities":{"discover":true}}
        """
        return try JSONDecoder().decode(MobileAPIV1.ServerInfoDTO.self, from: Data(fixture.utf8))
    }

    func searchSongs(query: String, session: DeviceSession) async throws -> [CatalogSong] {
        if query == "old" { await gate?.suspend() }
        let libraryOnly = await policy.currentLibraryOnly()
        return [try makeCatalogSong(title: query, source: libraryOnly ? "library" : "youtube")]
    }

    func searchAlbums(query: String, limit: Int, session: DeviceSession) async throws -> [CatalogAlbum] { [] }
    func searchArtists(query: String, session: DeviceSession) async throws -> [CatalogArtist] { [] }
    func search(query: String, albumLimit: Int, session: DeviceSession) async throws -> CatalogSearchResults { .init() }
    func resolve(url: String, session: DeviceSession) async throws -> URLResolution { throw CatalogAPIError.featureUnavailable }
    func preview(artist: String, title: String, duration: Double?, session: DeviceSession) async throws -> URL? { nil }
    func finderSearch(query: String, limit: Int, session: DeviceSession) async throws -> CatalogSearchResults { .init() }
    func finderArtist(id: String, language: String, session: DeviceSession) async throws -> CatalogFinderArtist { throw CatalogAPIError.featureUnavailable }
    func finderArtistSongs(id: String, name: String, session: DeviceSession) async throws -> CatalogSearchResults { .init() }
    func finderArtistAlbums(id: String, session: DeviceSession) async throws -> [CatalogAlbum] { [] }
    func finderAlbumTrackCounts(ids: [String], session: DeviceSession) async throws -> [String: Int] { [:] }
    func finderAlbum(id: String, session: DeviceSession) async throws -> CatalogFinderAlbum { throw CatalogAPIError.featureUnavailable }
    func charts(limit: Int, session: DeviceSession) async throws -> CatalogCharts {
        CatalogCharts(tracks: [], albums: [], artists: [], playlists: [])
    }
    func similar(artist: String, track: String, limit: Int, session: DeviceSession) async throws -> CatalogSimilarResults {
        CatalogSimilarResults(artist: artist, track: track, source: "library", tracks: [])
    }
    func discover(library: [CatalogLibraryArtist], session: DeviceSession) async throws -> CatalogDiscoverResults {
        CatalogDiscoverResults(artists: [], seeds: [], partial: discoverPartial)
    }
    func deezerCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistNames: [String], session: DeviceSession) async throws -> CatalogCollectionsResults {
        CatalogCollectionsResults(source: "deezer", albums: [], moreAlbums: [], playlists: [], partial: discoverPartial)
    }
    func spotifyCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistIDs: [String], shown: [String], session: DeviceSession) async throws -> CatalogCollectionsResults {
        if spotifyFails { throw APIError.httpStatus(502, retryAfter: nil) }
        return CatalogCollectionsResults(source: "spotify", albums: [], moreAlbums: [], playlists: [], partial: false)
    }
    func blockedArtists(session: DeviceSession) async throws -> [CatalogBlockedArtist] { [] }
    func blockArtist(name: String, session: DeviceSession) async throws -> CatalogBlockedArtist {
        CatalogBlockedArtist(name: name, blockedAt: "")
    }
    func unblockArtist(name: String, session: DeviceSession) async throws {}
}

private func makeCatalogSong(title: String, source: String) throws -> CatalogSong {
    let fixture = #"{"source":"\#(source)","song_id":"\#(title)","name":"\#(title)","artists":["Artist"],"url":""}"#
    return try JSONDecoder().decode(CatalogSong.self, from: Data(fixture.utf8))
}
