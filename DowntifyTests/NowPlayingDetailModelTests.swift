import XCTest
@testable import Downtify

@MainActor
final class NowPlayingDetailModelTests: XCTestCase {
    func testUnavailableWithoutSessionOrInLibraryOnlyMode() async {
        let stub = DetailCatalogStub()
        let model = NowPlayingDetailModel(api: stub)

        await model.loadArtist(.init(name: "Portishead"), session: nil, providerDetailsAvailable: true)
        XCTAssertEqual(model.artistState, .unavailable(message: "Connect to a server to browse this artist."))
        await model.loadAlbum(.init(title: "Dummy", artist: "Portishead"), session: makeSession(), providerDetailsAvailable: false)
        XCTAssertEqual(model.albumState, .unavailable(message: "Provider album details are unavailable in library-only mode."))
        XCTAssertEqual(stub.calls, [])
    }

    func testProviderArtistIDSkipsSearchAndLoadsEverything() async throws {
        let stub = DetailCatalogStub()
        stub.artistSongs = [try song("Roads")]
        stub.artistAlbums = [try album(id: "302127", title: "Dummy")]
        let model = NowPlayingDetailModel(api: stub)

        await model.loadArtist(.init(name: "Portishead", providerArtistID: "27"), session: makeSession(), providerDetailsAvailable: true)

        guard case .loaded(let value) = model.artistState else { return XCTFail("\(model.artistState)") }
        XCTAssertEqual(value.artist.name, "Portishead")
        XCTAssertEqual(value.bio, "Bristol band")
        XCTAssertEqual(value.songs.map(\.title), ["Roads"])
        XCTAssertEqual(value.albums.map(\.albumID), ["302127"])
        XCTAssertFalse(stub.calls.contains { $0.hasPrefix("search") })
        XCTAssertTrue(stub.calls.contains("artist:27"))
    }

    func testArtistNameResolvesThroughFinderSearch() async throws {
        let stub = DetailCatalogStub()
        stub.searchResults = try decodeSearch(#"{"artists":[{"source":"deezer","artist_id":"5","name":"Portishead Tribute"},{"source":"deezer","artist_id":"27","name":"portishead"}]}"#)
        let model = NowPlayingDetailModel(api: stub)

        await model.loadArtist(.init(name: "Portishead"), session: makeSession(), providerDetailsAvailable: true)

        XCTAssertTrue(stub.calls.contains("search:Portishead"))
        XCTAssertTrue(stub.calls.contains("artist:27"))
        guard case .loaded(let value) = model.artistState else { return XCTFail("\(model.artistState)") }
        XCTAssertEqual(value.songs.map(\.title), ["Top"], "Falls back to top songs when the song search is empty")
    }

    func testNoCatalogMatchIsEmpty() async {
        let stub = DetailCatalogStub()
        let model = NowPlayingDetailModel(api: stub)

        await model.loadArtist(.init(name: "Nobody"), session: makeSession(), providerDetailsAvailable: true)
        XCTAssertEqual(model.artistState, .empty)
        await model.loadAlbum(.init(title: "Nothing", artist: "Nobody"), session: makeSession(), providerDetailsAvailable: true)
        XCTAssertEqual(model.albumState, .empty)
        XCTAssertFalse(stub.calls.contains { $0.hasPrefix("artist:") || $0.hasPrefix("album:") })
    }

    func testArtistDetailsFailureFails() async {
        let stub = DetailCatalogStub()
        stub.artistError = APIError.httpStatus(502, retryAfter: nil)
        let model = NowPlayingDetailModel(api: stub)

        await model.loadArtist(.init(name: "Portishead", providerArtistID: "27"), session: makeSession(), providerDetailsAvailable: true)

        XCTAssertEqual(model.artistState, .failed(message: "The server could not complete this request (502)."))
    }

    func testArtistAlbumsFailureIsPartial() async {
        let stub = DetailCatalogStub()
        stub.albumsError = APIError.invalidResponse
        let model = NowPlayingDetailModel(api: stub)

        await model.loadArtist(.init(name: "Portishead", providerArtistID: "27"), session: makeSession(), providerDetailsAvailable: true)

        guard case .partial(let value, _) = model.artistState else { return XCTFail("\(model.artistState)") }
        XCTAssertEqual(value.albums, [])
    }

    func testAlbumLoadsByProviderIDOrSearch() async throws {
        let stub = DetailCatalogStub()
        stub.searchResults = try decodeSearch(#"{"albums":[{"source":"deezer","album_id":"9","name":"Dummy (Live)","artist":"Portishead"},{"source":"deezer","album_id":"302127","name":"Dummy","artist":"Portishead"}]}"#)
        let model = NowPlayingDetailModel(api: stub)

        await model.loadAlbum(.init(title: "Dummy", artist: "Portishead"), session: makeSession(), providerDetailsAvailable: true)

        XCTAssertTrue(stub.calls.contains("search:Portishead Dummy"))
        XCTAssertTrue(stub.calls.contains("album:302127"))
        guard case .loaded(let value) = model.albumState else { return XCTFail("\(model.albumState)") }
        XCTAssertEqual(value.tracks.map(\.title), ["Mysterons", "Sour Times"])

        stub.calls = []
        await model.loadAlbum(.init(title: "Dummy", artist: "Portishead", providerAlbumID: "302127"),
                              session: makeSession(), providerDetailsAvailable: true)
        XCTAssertEqual(stub.calls, ["album:302127"])
    }

    func testAlbumWithoutTracksIsEmptyAndLibraryOnlyErrorIsUnavailable() async {
        let stub = DetailCatalogStub()
        stub.albumTracksJSON = "[]"
        let model = NowPlayingDetailModel(api: stub)
        await model.loadAlbum(.init(title: "Dummy", artist: "Portishead", providerAlbumID: "1"), session: makeSession(), providerDetailsAvailable: true)
        XCTAssertEqual(model.albumState, .empty)

        stub.albumError = CatalogAPIError.libraryOnly
        await model.loadAlbum(.init(title: "Dummy", artist: "Portishead", providerAlbumID: "1"), session: makeSession(), providerDetailsAvailable: true)
        XCTAssertEqual(model.albumState, .unavailable(message: "External catalog actions are unavailable in library-only mode."))
    }

    func testNewerAlbumLoadWinsOverSlowerEarlierLoad() async throws {
        let stub = DetailCatalogStub()
        let gate = DetailGate()
        stub.albumGate = ("slow", gate)
        let model = NowPlayingDetailModel(api: stub)

        let first = Task { await model.loadAlbum(.init(title: "Slow", artist: "A", providerAlbumID: nil), session: makeSession(), providerDetailsAvailable: true) }
        stub.searchResults = try decodeSearch(#"{"albums":[{"source":"deezer","album_id":"1","name":"Slow","artist":"A"}]}"#)
        await waitUntil { stub.calls.contains("search:A Slow") }
        await model.loadAlbum(.init(title: "Fast", artist: "B", providerAlbumID: "2"), session: makeSession(), providerDetailsAvailable: true)
        guard case .loaded = model.albumState else { return XCTFail("\(model.albumState)") }
        let fastState = model.albumState

        await gate.open()
        await first.value
        XCTAssertEqual(model.albumState, fastState)
    }

    // MARK: Helpers

    private func makeSession() -> DeviceSession {
        DeviceSession(baseAddress: "https://example.test", serverID: "server", serverName: "Server", deviceID: "device",
                      username: "listener", role: nil, token: "secret", allowsInsecureHTTP: false)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private func song(_ title: String) throws -> CatalogSong {
        try JSONDecoder().decode(CatalogSong.self, from: Data(#"{"source":"deezer","song_id":"\#(title)","name":"\#(title)","artist":"Portishead"}"#.utf8))
    }

    private func album(id: String, title: String) throws -> CatalogAlbum {
        try JSONDecoder().decode(CatalogAlbum.self, from: Data(#"{"source":"deezer","album_id":"\#(id)","name":"\#(title)","artist":"Portishead"}"#.utf8))
    }

    private func decodeSearch(_ json: String) throws -> CatalogSearchResults {
        try JSONDecoder().decode(CatalogSearchResults.self, from: Data(json.utf8))
    }
}

actor DetailGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Configurable Finder responses; everything else is unavailable.
@MainActor
private final class DetailCatalogStub: CatalogServing {
    var calls: [String] = []
    var searchResults = CatalogSearchResults()
    var artistSongs: [CatalogSong] = []
    var artistAlbums: [CatalogAlbum] = []
    var artistError: Error?
    var albumsError: Error?
    var albumError: Error?
    var albumTracksJSON = #"[{"source":"deezer","song_id":"1","name":"Mysterons","track_number":1},{"source":"deezer","song_id":"2","name":"Sour Times","track_number":2}]"#
    var albumGate: (title: String, gate: DetailGate)?

    nonisolated init() {}

    func finderSearch(query: String, limit: Int, session: DeviceSession) async throws -> CatalogSearchResults {
        calls.append("search:\(query)")
        let results = searchResults
        if let albumGate, query.localizedCaseInsensitiveContains(albumGate.title) { await albumGate.gate.wait() }
        return results
    }

    func finderArtist(id: String, language: String, session: DeviceSession) async throws -> CatalogFinderArtist {
        calls.append("artist:\(id)")
        if let artistError { throw artistError }
        let json = #"{"source":"deezer","artist_id":"\#(id)","name":"Portishead","bio":"Bristol band","top_songs":[{"source":"deezer","song_id":"t","name":"Top"}]}"#
        return try JSONDecoder().decode(CatalogFinderArtist.self, from: Data(json.utf8))
    }

    func finderArtistSongs(id: String, name: String, session: DeviceSession) async throws -> CatalogSearchResults {
        calls.append("songs:\(id)")
        return CatalogSearchResults(tracks: artistSongs, albums: [], artists: [])
    }

    func finderArtistAlbums(id: String, session: DeviceSession) async throws -> [CatalogAlbum] {
        calls.append("albums:\(id)")
        if let albumsError { throw albumsError }
        return artistAlbums
    }

    func finderAlbum(id: String, session: DeviceSession) async throws -> CatalogFinderAlbum {
        calls.append("album:\(id)")
        if let albumError { throw albumError }
        let json = #"{"source":"deezer","album_id":"\#(id)","name":"Dummy","artist":"Portishead","tracks":\#(albumTracksJSON)}"#
        return try JSONDecoder().decode(CatalogFinderAlbum.self, from: Data(json.utf8))
    }

    func serverInfo(session: DeviceSession) async throws -> MobileAPIV1.ServerInfoDTO { throw CatalogAPIError.featureUnavailable }
    func searchSongs(query: String, session: DeviceSession) async throws -> [CatalogSong] { [] }
    func searchAlbums(query: String, limit: Int, session: DeviceSession) async throws -> [CatalogAlbum] { [] }
    func searchArtists(query: String, session: DeviceSession) async throws -> [CatalogArtist] { [] }
    func search(query: String, albumLimit: Int, session: DeviceSession) async throws -> CatalogSearchResults { .init() }
    func resolve(url: String, session: DeviceSession) async throws -> URLResolution { throw CatalogAPIError.featureUnavailable }
    func albumTracks(url: String, session: DeviceSession) async throws -> [CatalogSong] { [] }
    func preview(artist: String, title: String, duration: Double?, session: DeviceSession) async throws -> URL? { nil }
    func finderAlbumTrackCounts(ids: [String], session: DeviceSession) async throws -> [String: Int] { [:] }
    func charts(limit: Int, session: DeviceSession) async throws -> CatalogCharts { throw CatalogAPIError.featureUnavailable }
    func similar(artist: String, track: String, limit: Int, session: DeviceSession) async throws -> CatalogSimilarResults { throw CatalogAPIError.featureUnavailable }
    func discover(library: [CatalogLibraryArtist], session: DeviceSession) async throws -> CatalogDiscoverResults { throw CatalogAPIError.featureUnavailable }
    func deezerCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistNames: [String], session: DeviceSession) async throws -> CatalogCollectionsResults { throw CatalogAPIError.featureUnavailable }
    func spotifyCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistIDs: [String], shown: [String], session: DeviceSession) async throws -> CatalogCollectionsResults { throw CatalogAPIError.featureUnavailable }
    func blockedArtists(session: DeviceSession) async throws -> [CatalogBlockedArtist] { [] }
    func blockArtist(name: String, session: DeviceSession) async throws -> CatalogBlockedArtist { throw CatalogAPIError.featureUnavailable }
    func unblockArtist(name: String, session: DeviceSession) async throws {}
}
