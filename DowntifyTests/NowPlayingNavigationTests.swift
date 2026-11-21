import XCTest
@testable import Downtify

final class NowPlayingNavigationTests: XCTestCase {
    // MARK: Targets

    func testLibraryTrackTargetsUseLibraryIDs() {
        let track = makeTrack(id: "t1", title: "Roads")
        let catalog = LibraryCatalog([track])

        let artists = NowPlayingNavigationResolver.artistTargets(for: .library(track), catalog: catalog)
        XCTAssertEqual(artists, [NowPlayingArtistTarget(name: "Portishead", libraryArtistID: "artist-1")])

        let album = NowPlayingNavigationResolver.albumTarget(for: .library(track), catalog: catalog)
        XCTAssertEqual(album, NowPlayingAlbumTarget(title: "Dummy", artist: "Portishead", libraryAlbumID: "album-1"))
    }

    func testLibraryTrackWithoutAlbumHasNoAlbumTarget() {
        let track = makeTrack(id: "t1", title: "Single", album: "  ", albumID: "")
        XCTAssertNil(NowPlayingNavigationResolver.albumTarget(for: .library(track), catalog: LibraryCatalog([track])))
    }

    func testLibraryTrackListsFeaturedArtistsWithoutDuplicates() {
        let track = makeTrack(id: "t1", title: "Song", artist: "Beyoncé", artists: ["Beyoncé", "beyonce", "Jay-Z", ""],
                              albumArtist: "Beyoncé")
        let names = NowPlayingNavigationResolver.artistTargets(for: .library(track), catalog: LibraryCatalog([track])).map(\.name)
        XCTAssertEqual(names, ["Beyoncé", "Jay-Z"])
    }

    func testCatalogSongKeepsDecimalProviderIDsOnly() throws {
        let song = try decodeSong(#"{"source":"deezer","song_id":"1","name":"Roads","artist":"Portishead","album_name":"Dummy","deezer_artist_id":"27","deezer_album_id":"302127"}"#)
        let catalog = LibraryCatalog([])
        XCTAssertEqual(NowPlayingNavigationResolver.artistTargets(for: .catalog(song), catalog: catalog),
                       [NowPlayingArtistTarget(name: "Portishead", providerArtistID: "27")])
        XCTAssertEqual(NowPlayingNavigationResolver.albumTarget(for: .catalog(song), catalog: catalog),
                       NowPlayingAlbumTarget(title: "Dummy", artist: "Portishead", providerAlbumID: "302127", providerArtistID: "27"))

        let spotify = try decodeSong(#"{"source":"spotify","song_id":"2","name":"Roads","artist":"Portishead","album_name":"Dummy","deezer_artist_id":"abc","deezer_album_id":"x1"}"#)
        XCTAssertNil(NowPlayingNavigationResolver.artistTargets(for: .catalog(spotify), catalog: catalog).first?.providerArtistID)
        XCTAssertNil(NowPlayingNavigationResolver.albumTarget(for: .catalog(spotify), catalog: catalog)?.providerAlbumID)
    }

    func testCatalogSongWithoutAlbumHasNoAlbumTarget() throws {
        let song = try decodeSong(#"{"source":"youtube","song_id":"1","name":"Live","artist":"Someone"}"#)
        XCTAssertNil(NowPlayingNavigationResolver.albumTarget(for: .catalog(song), catalog: LibraryCatalog([])))
    }

    func testCatalogSongFindsUniqueLibraryMatchByNormalizedName() throws {
        let track = makeTrack(id: "t1", title: "Roads")
        let song = try decodeSong(#"{"source":"deezer","song_id":"1","name":"Roads","artist":"PORTISHEAD ","album_name":"dummy"}"#)
        let catalog = LibraryCatalog([track])
        XCTAssertEqual(NowPlayingNavigationResolver.artistTargets(for: .catalog(song), catalog: catalog).first?.libraryArtistID, "artist-1")
        XCTAssertEqual(NowPlayingNavigationResolver.albumTarget(for: .catalog(song), catalog: catalog)?.libraryAlbumID, "album-1")
    }

    func testAmbiguousLibraryArtistNameGivesNoLibraryID() {
        let first = makeTrack(id: "t1", title: "A", artistID: "artist-1")
        let second = makeTrack(id: "t2", title: "B", albumID: "album-2", artistID: "artist-2")
        let catalog = LibraryCatalog([first, second])
        XCTAssertNil(NowPlayingNavigationResolver.uniqueLibraryArtistID(named: "Portishead", in: catalog))
    }

    func testEmptyLibraryArtistNameIsDropped() throws {
        let song = try decodeSong(#"{"source":"youtube","song_id":"1","name":"Untitled","artist":""}"#)
        XCTAssertTrue(NowPlayingNavigationResolver.artistTargets(for: .catalog(song), catalog: LibraryCatalog([])).isEmpty)
    }

    func testCatalogSongMatchesOneLibraryTrackByTitleAndArtist() throws {
        let roads = makeTrack(id: "t1", title: "Roads")
        let song = try decodeSong(#"{"source":"deezer","song_id":"1","name":"roads","artist":"Portishead"}"#)
        XCTAssertEqual(NowPlayingNavigationResolver.libraryTrack(matching: song, in: [roads]), roads)
        let live = makeTrack(id: "t2", title: "Roads", album: "Roseland NYC Live", albumID: "album-2")
        XCTAssertNil(NowPlayingNavigationResolver.libraryTrack(matching: song, in: [roads, live]))
        let other = try decodeSong(#"{"source":"deezer","song_id":"2","name":"Roads","artist":"Cover Band"}"#)
        XCTAssertNil(NowPlayingNavigationResolver.libraryTrack(matching: other, in: [roads]))
    }

    // MARK: Matching

    func testBestArtistMatches() throws {
        XCTAssertNil(CatalogNameMatch.bestArtist(named: "Portishead", in: []))
        let artists = try [
            decodeArtist(#"{"source":"deezer","artist_id":"1","name":"Portishead Tribute","fans":900}"#),
            decodeArtist(#"{"source":"deezer","artist_id":"2","name":"portishead","fans":10}"#),
            decodeArtist(#"{"source":"spotify","artist_id":"abc","name":"Portishead","fans":99999}"#),
            decodeArtist(#"{"source":"deezer","artist_id":"3","name":"Portishéad","fans":50}"#),
            decodeArtist(#"{"source":"deezer","artist_id":"4","name":"Portishead","fans":50}"#)
        ]
        XCTAssertEqual(CatalogNameMatch.bestArtist(named: "Portishead", in: Array(artists.prefix(2)))?.artistID, "2")
        XCTAssertEqual(CatalogNameMatch.bestArtist(named: "Portishead", in: artists)?.artistID, "3")
        XCTAssertNil(CatalogNameMatch.bestArtist(named: "Massive Attack", in: artists))
    }

    func testBestAlbumMatchesFirstInServerOrder() throws {
        let albums = try [
            decodeAlbum(#"{"source":"deezer","album_id":"10","name":"Dummy (Deluxe)","artist":"Portishead"}"#),
            decodeAlbum(#"{"source":"deezer","album_id":"11","name":"Dummy","artist":"Other"}"#),
            decodeAlbum(#"{"source":"deezer","album_id":"12","name":"dummy","artist":"Portishead"}"#),
            decodeAlbum(#"{"source":"deezer","album_id":"13","name":"Dummy","artist":"Portishead"}"#)
        ]
        XCTAssertEqual(CatalogNameMatch.bestAlbum(title: "Dummy", artist: "Portishead", in: albums)?.albumID, "12")
        XCTAssertNil(CatalogNameMatch.bestAlbum(title: "Third", artist: "Portishead", in: albums))
        XCTAssertNil(CatalogNameMatch.bestAlbum(title: "Dummy", artist: "Portishead", in: []))
    }

    // MARK: Merging

    func testPartlyOwnedAlbumMergesInProviderOrder() throws {
        let owned = makeTrack(id: "t2", title: "Sour Times", trackNumber: 2)
        let extra = makeTrack(id: "t9", title: "Bonus Demo", trackNumber: 0)
        let songs = try [song("Mysterons", 1), song("sour times", 2), song("Strangers", 3)]

        let rows = AlbumTrackMerge.rows(catalogTracks: songs, libraryTracks: [owned, extra])

        XCTAssertEqual(rows, [.catalogOnly(songs[0]), .owned(owned, catalog: songs[1]), .catalogOnly(songs[2]), .libraryOnly(extra)])
        XCTAssertEqual(AlbumTrackMerge.playbackItems(rows, includeCatalog: true),
                       [.catalog(songs[0]), .library(owned), .catalog(songs[2]), .library(extra)])
        XCTAssertEqual(AlbumTrackMerge.playbackItems(rows, includeCatalog: false), [.library(owned), .library(extra)])
    }

    func testFullyOwnedAndCatalogOnlyAlbums() throws {
        let tracks = [makeTrack(id: "t1", title: "One", trackNumber: 1), makeTrack(id: "t2", title: "Two", trackNumber: 2)]
        let songs = try [song("One", 1), song("Two", 2)]
        XCTAssertEqual(AlbumTrackMerge.rows(catalogTracks: songs, libraryTracks: tracks),
                       [.owned(tracks[0], catalog: songs[0]), .owned(tracks[1], catalog: songs[1])])
        XCTAssertEqual(AlbumTrackMerge.rows(catalogTracks: songs, libraryTracks: []), songs.map(AlbumPageRow.catalogOnly))
        XCTAssertEqual(AlbumTrackMerge.rows(catalogTracks: [], libraryTracks: tracks), tracks.map(AlbumPageRow.libraryOnly))
    }

    func testDuplicateTitlesResolveByTrackNumber() throws {
        let first = makeTrack(id: "t1", title: "Intro", trackNumber: 1)
        let last = makeTrack(id: "t5", title: "Intro", trackNumber: 5)
        let songs = try [song("Intro", 5), song("Intro", 1)]
        XCTAssertEqual(AlbumTrackMerge.rows(catalogTracks: songs, libraryTracks: [first, last]),
                       [.owned(last, catalog: songs[0]), .owned(first, catalog: songs[1])])
    }

    func testArtistCatalogAlbumsExcludeLibraryAlbums() throws {
        let track = makeTrack(id: "t1", title: "Roads")
        let libraryAlbums = LibraryCatalog([track]).albums(for: "artist-1")
        let albums = try [
            decodeAlbum(#"{"source":"deezer","album_id":"1","name":"DUMMY","artist":"Portishead"}"#),
            decodeAlbum(#"{"source":"deezer","album_id":"2","name":"Third","artist":"Portishead"}"#)
        ]
        XCTAssertEqual(ArtistAlbumMerge.catalogOnly(providerAlbums: albums, libraryAlbums: libraryAlbums).map(\.albumID), ["2"])
    }

    // MARK: Helpers

    private func song(_ title: String, _ number: Int) throws -> CatalogSong {
        try decodeSong(#"{"source":"deezer","song_id":"\#(title)-\#(number)","name":"\#(title)","artist":"Portishead","album_name":"Dummy","track_number":\#(number)}"#)
    }

    private func decodeSong(_ json: String) throws -> CatalogSong {
        try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
    }

    private func decodeArtist(_ json: String) throws -> CatalogArtist {
        try JSONDecoder().decode(CatalogArtist.self, from: Data(json.utf8))
    }

    private func decodeAlbum(_ json: String) throws -> CatalogAlbum {
        try JSONDecoder().decode(CatalogAlbum.self, from: Data(json.utf8))
    }

    private func makeTrack(id: String, title: String, artist: String = "Portishead", artists: [String] = ["Portishead"],
                           album: String = "Dummy", albumArtist: String = "Portishead", albumID: String = "album-1",
                           artistID: String = "artist-1", trackNumber: Int = 1) -> LibraryTrack {
        LibraryTrack(id: id, file: "Music/\(id).flac", title: title, artist: artist, artists: artists, album: album,
                     albumArtist: albumArtist, albumID: albumID, artistID: artistID, trackNumber: trackNumber, year: "1994",
                     duration: 240, codec: "flac", bitrate: 900_000, sampleRate: 44_100, channels: 2,
                     size: 1_024, added: 1, hasCover: false, isExplicit: false, playlists: [])
    }
}
