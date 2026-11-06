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
        let repository = LibraryRepository(database: database, feed: Feed([]), session: { await sessions.value })
        let model = LibraryPresentationModel(repository: repository, sessionUpdates: { updates })
        model.start()
        await sessions.set(first)
        continuation.yield(first)
        await waitUntil { model.state == .empty }
        await sessions.set(second)
        continuation.yield(second)
        // Wait for the session event to be consumed before waiting for its empty snapshot.
        // Checking for .empty immediately can pass on the first session's existing state.
        await waitUntil { model.state == .loading }
        await waitUntil { model.state == .empty }
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

private func makeTrack(_ id: String, title: String? = nil, artist: String = "", album: String = "") -> LibraryTrack {
    LibraryTrack(id: id, file: "\(id).mp3", title: title ?? id, artist: artist, artists: [], album: album, albumArtist: "",
                 albumID: "", artistID: "", trackNumber: 0, year: "", duration: 0, codec: "mp3", bitrate: 0,
                 sampleRate: 0, channels: 0, size: 0, added: 0, hasCover: false, isExplicit: false, playlists: [])
}
