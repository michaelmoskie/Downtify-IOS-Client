import Foundation
import XCTest
@testable import Downtify

final class PlaybackQueueTests: XCTestCase {
    func testLegacyTrackIDQueueEntryDecodesAndRetainsState() throws {
        let occurrence = UUID(uuidString: "A8C8CA9C-2B3D-4D03-A1F4-35367B4990CD")!
        let legacy = #"{"entries":[{"id":"\#(occurrence.uuidString)","trackID":"library-id"}],"shuffledIDs":["\#(occurrence.uuidString)"],"currentID":"\#(occurrence.uuidString)","position":13.5,"repeatMode":"all","listen":null}"#
        let saved = try JSONDecoder().decode(SavedPlaybackQueue.self, from: Data(legacy.utf8))
        XCTAssertEqual(saved.entries.first?.trackID, "library-id")
        XCTAssertNil(saved.entries.first?.catalogSong)

        var queue = PlaybackQueue()
        XCTAssertEqual(queue.restore(saved, tracks: [libraryTrack(id: "library-id", file: "music/song.mp3")]), 13.5)
        XCTAssertEqual(queue.currentID, occurrence)
        XCTAssertEqual(queue.repeatMode, .all)
        XCTAssertEqual(queue.order.first?.track.id, "library-id")
    }

    func testMixedQueuePersistsCatalogPayloadAndRestoresOccurrencesLosslessly() throws {
        let library = libraryTrack(id: "same-id", file: "music/library.mp3")
        let catalog = try catalogSong(#"{"source":"youtube","song_id":"same-id","youtube_id":"video-1","name":"Catalog title","artist":"Catalog artist","artists":["Catalog artist"],"album_name":"Remote album","duration":91.5,"url":"https://catalog.test/watch","extra":{"provider_flag":true}}"#)
        var queue = PlaybackQueue()
        queue.replace([.library(library), .catalog(catalog), .catalog(catalog)], startingAt: 1)
        let selectedID = try XCTUnwrap(queue.currentID)
        queue.setShuffle(true)
        queue.repeatMode = .one

        let encoded = try JSONEncoder().encode(queue.saved(position: 21))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["trackID"] as? String, "same-id")
        XCTAssertNil(entries[0]["catalogSong"])
        let storedCatalog = try XCTUnwrap(entries[1]["catalogSong"] as? [String: Any])
        let storedCatalogData = try JSONSerialization.data(withJSONObject: storedCatalog)
        XCTAssertEqual(try JSONDecoder().decode(CatalogSong.self, from: storedCatalogData), catalog)
        XCTAssertNil(entries[1]["trackID"])

        let saved = try JSONDecoder().decode(SavedPlaybackQueue.self, from: encoded)
        var restored = PlaybackQueue()
        XCTAssertEqual(restored.restore(saved, tracks: [library]), 21)
        XCTAssertEqual(restored.currentID, selectedID)
        XCTAssertEqual(restored.repeatMode, .one)
        XCTAssertEqual(restored.entries.map(\.id), queue.entries.map(\.id))
        XCTAssertEqual(restored.order.map(\.id), queue.order.map(\.id))
        XCTAssertEqual(restored.entries[1].item, .catalog(catalog))
        XCTAssertEqual(restored.entries[2].item, .catalog(catalog))
        XCTAssertNotEqual(restored.entries[1].id, restored.entries[2].id)
    }

    func testLibraryCatalogRowsResolveOnlyByUniqueExactFile() throws {
        let row = try catalogSong(#"{"source":"library","name":"Song","file":"Music/song.flac"}"#)
        let matching = libraryTrack(id: "scoped-id", file: "Music/song.flac")
        XCTAssertEqual(PlaybackItem.resolving(row, in: [matching]), .library(matching))
        XCTAssertEqual(PlaybackItem.resolving(row, in: [matching, libraryTrack(id: "other", file: "Music/song.flac")]), .catalog(row))
        XCTAssertEqual(PlaybackItem.resolving(row, in: [libraryTrack(id: "other", file: "Music/elsewhere.flac")]), .catalog(row))

        var queue = PlaybackQueue()
        queue.replace([.catalog(row)], startingAt: 0)
        let saved = queue.saved(position: 7)
        var restored = PlaybackQueue()
        XCTAssertEqual(restored.restore(saved, tracks: [matching]), 7)
        XCTAssertEqual(restored.current?.item, .library(matching))

        var unavailable = PlaybackQueue()
        XCTAssertEqual(unavailable.restore(saved, tracks: []), 0)
        XCTAssertTrue(unavailable.entries.isEmpty)
    }

    func testLibraryOnlyPolicyConvertsLocalRowsPrunesOthersAndKeepsQueueState() throws {
        let first = libraryTrack(id: "first", file: "Music/first.flac")
        let matched = libraryTrack(id: "matched", file: "Music/local.flac")
        let last = libraryTrack(id: "last", file: "Music/last.flac")
        let local = try catalogSong(#"{"source":"library","name":"Local","file":"Music/local.flac"}"#)
        let staleLocal = try catalogSong(#"{"source":"library","name":"Stale","file":"Music/stale.flac"}"#)
        let remote = try catalogSong(#"{"source":"youtube","name":"Remote","youtube_id":"remote-1"}"#)

        var queue = PlaybackQueue()
        queue.replace([.library(first), .catalog(remote), .catalog(local), .catalog(staleLocal), .library(last)], startingAt: 1)
        queue.setShuffle(true)
        queue.repeatMode = .all
        let oldOrderIDs = queue.order.map(\.id)
        let oldCurrentID = try XCTUnwrap(queue.currentID)
        let localID = try XCTUnwrap(queue.entries.first(where: { $0.item.catalogSong == local })?.id)
        let retainedIDs: Set<UUID> = [queue.entries[0].id, localID, queue.entries[4].id]
        let expectedCurrent = try XCTUnwrap(oldOrderIDs.dropFirst().first(where: retainedIDs.contains))

        queue.applyLibraryOnlyPolicy(true, tracks: [matched, first, last])

        XCTAssertEqual(queue.repeatMode, .all)
        XCTAssertNotNil(queue.shuffledIDs)
        XCTAssertEqual(queue.order.map(\.id), oldOrderIDs.filter(retainedIDs.contains))
        XCTAssertEqual(queue.currentID, expectedCurrent)
        XCTAssertNotEqual(queue.currentID, oldCurrentID)
        XCTAssertEqual(queue.entries.map { $0.item.libraryTrack?.id }, ["first", "matched", "last"])
        XCTAssertTrue(queue.entries.allSatisfy { $0.item.catalogSong == nil })
    }

    private func catalogSong(_ json: String) throws -> CatalogSong {
        try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
    }

    private func libraryTrack(id: String, file: String) -> LibraryTrack {
        LibraryTrack(id: id, file: file, title: "Library title", artist: "Library artist", artists: ["Library artist"],
                     album: "Library album", albumArtist: "Library artist", albumID: "album", artistID: "artist",
                     trackNumber: 1, year: "2026", duration: 100, codec: "flac", bitrate: 900_000,
                     sampleRate: 44_100, channels: 2, size: 100, added: 0, hasCover: false,
                     isExplicit: false, playlists: [])
    }
}
