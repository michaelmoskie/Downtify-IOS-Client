import Foundation
import SQLite3
import XCTest
@testable import Downtify

final class LibrarySyncTests: XCTestCase {
    func testInitialIncrementalRepeatedAndFullSync() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("a"), track("b")], etag: "first"),
            .page(12, tracks: [track("a", title: "Renamed"), track("c")], deleted: ["b"], etag: "delta"),
            .page(12, etag: "unchanged"),
            .result(.unchanged),
            .page(3, full: true, tracks: [track("d")])
        ])
        let repository = LibraryRepository(database: database, feed: feed, session: { session })

        let initial = try await repository.sync()
        XCTAssertEqual(initial, .replaced(trackCount: 2))
        let incremental = try await repository.sync()
        XCTAssertEqual(incremental, .applied(changed: 2, deleted: 1))
        let updated = try await repository.snapshot()
        XCTAssertEqual(updated, LibrarySnapshot(cursor: 12, tracks: [track("a", title: "Renamed"), track("c")]))
        let byID = try await repository.track(id: "a")
        XCTAssertEqual(byID?.title, "Renamed")

        let emptyDelta = try await repository.sync()
        XCTAssertEqual(emptyDelta, .unchanged)
        let notModified = try await repository.sync()
        XCTAssertEqual(notModified, .unchanged)
        let stillUpdated = try await repository.snapshot()
        XCTAssertEqual(stillUpdated, updated)

        let full = try await repository.sync(refresh: true)
        XCTAssertEqual(full, .replaced(trackCount: 1))
        let replaced = try await repository.snapshot()
        XCTAssertEqual(replaced, LibrarySnapshot(cursor: 3, tracks: [track("d")]))

        let requests = await feed.requests
        XCTAssertEqual(requests.map(\.cursor), [0, 10, 12, 12, 12])
        XCTAssertEqual(requests.map(\.etag), [nil, nil, nil, "unchanged", nil])
        XCTAssertEqual(requests.map(\.refresh), [false, false, false, false, true])
    }

    func testRejectedFullPageRollsBackRowsAndCheckpoint() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("original")]),
            .page(11, full: true, tracks: [track("already-inserted"), track("")]),
            .page(12, tracks: [track("retry")])
        ])
        let repository = LibraryRepository(database: database, feed: feed, session: { session })

        _ = try await repository.sync()
        do {
            _ = try await repository.sync()
            XCTFail("Expected a rejected row")
        } catch let error as LibraryDatabaseError {
            XCTAssertEqual(error, .invalidPage)
        }
        let retained = try await repository.snapshot()
        XCTAssertEqual(retained, LibrarySnapshot(cursor: 10, tracks: [track("original")]))
        _ = try await repository.sync()
        let updated = try await repository.snapshot()
        XCTAssertEqual(updated, LibrarySnapshot(cursor: 12, tracks: [track("original"), track("retry")]))
        let requests = await feed.requests
        XCTAssertEqual(requests.map(\.cursor), [0, 10, 10])
    }

    func testCancelledFetchLeavesCursorAndTracksUnchanged() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let started = expectation(description: "Interrupted request started")
        let gate = AsyncGate()
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("before")]),
            .held(.page(LibraryPage(cursor: 11, full: false, tracks: [track("partial")], deleted: ["before"]), etag: nil),
                  started, gate)
        ])
        let repository = LibraryRepository(database: database, feed: feed, session: { session })

        _ = try await repository.sync()
        let sync = Task { try await repository.sync() }
        await fulfillment(of: [started], timeout: 3)
        sync.cancel()
        await gate.release()
        do {
            _ = try await sync.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let retained = try await repository.snapshot()
            XCTAssertEqual(retained, LibrarySnapshot(cursor: 10, tracks: [track("before")]))
        }
    }

    func testConflictingResponseRefetchesFromTheLatestCheckpoint() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let started = expectation(description: "Stale request started")
        let gate = AsyncGate()
        let stale = LibraryPage(cursor: 11, full: false, tracks: [track("stale")], deleted: [])
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("before")]),
            .held(.page(stale, etag: nil), started, gate),
            .page(12, tracks: [track("newer")], deleted: ["before"]),
            .page(13, tracks: [track("latest")])
        ])
        let repository = LibraryRepository(database: database, feed: feed, session: { session })

        _ = try await repository.sync()
        let slowSync = Task { try await repository.sync() }
        await fulfillment(of: [started], timeout: 3)
        do {
            _ = try await repository.sync()
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        _ = try await slowSync.value

        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot, LibrarySnapshot(cursor: 13, tracks: [track("latest"), track("newer")]))
        let requests = await feed.requests
        XCTAssertEqual(requests.map(\.cursor), [0, 10, 10, 12])
    }

    func testRetriesTransientErrorsAtTheSameCursorAndHonorsRetryAfter() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let waits = RecordedWaits()
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("before")]),
            .failure(.transportFailure),
            .failure(.httpStatus(429, retryAfter: 7)),
            .page(11, tracks: [track("retry")]),
            .failure(.httpStatus(403, retryAfter: nil))
        ])
        let repository = LibraryRepository(
            database: database, feed: feed, session: { session },
            wait: { await waits.record($0) }
        )

        _ = try await repository.sync()
        _ = try await repository.sync()
        do {
            _ = try await repository.sync()
            XCTFail("Expected the authorization failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(403, retryAfter: nil))
        }

        let requests = await feed.requests
        XCTAssertEqual(requests.map(\.cursor), [0, 10, 10, 10, 11])
        let durations = await waits.durations
        XCTAssertEqual(durations, [.milliseconds(250), .seconds(7)])
    }

    func testSameAccountKeepsItsCacheAcrossSignOutAndRePairing() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let state = SessionState(session)
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("alice")]),
            .page(5, full: true, tracks: [track("bob")])
        ])
        let repository = LibraryRepository(database: database, feed: feed, session: { await state.current })

        _ = try await repository.sync()
        await state.set(nil)
        do {
            _ = try await repository.snapshot()
            XCTFail("The previous account's library must be inaccessible while signed out")
        } catch let error as LibrarySyncError {
            XCTAssertEqual(error, .signedOut)
        }

        await state.set(testSession(username: "ALICE", deviceID: "replacement"))
        let retained = try await repository.snapshot()
        XCTAssertEqual(retained, LibrarySnapshot(cursor: 10, tracks: [track("alice")]))
        await state.set(testSession(username: "bob"))
        let empty = try await repository.snapshot()
        XCTAssertEqual(empty, LibrarySnapshot(cursor: nil, tracks: []))
        _ = try await repository.sync()
        let separate = try await repository.snapshot()
        XCTAssertEqual(separate, LibrarySnapshot(cursor: 5, tracks: [track("bob")]))
        await state.set(testSession(serverID: "different", username: "alice"))
        let newServer = try await repository.snapshot()
        XCTAssertEqual(newServer, LibrarySnapshot(cursor: nil, tracks: []))
    }

    func testVersionOneMigrationPreservesTrackAndCursor() async throws {
        let (database, folder) = try temporaryDatabase()
        let existing = track("existing")
        let payload = try JSONEncoder().encode(existing).map { String(format: "%02x", $0) }.joined()
        let file = folder.appending(path: "library.sqlite")
        try executeSQL("""
            CREATE TABLE library_tracks (server_id TEXT NOT NULL, account TEXT NOT NULL,
                track_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (server_id, account, track_id)) WITHOUT ROWID;
            CREATE TABLE library_checkpoints (server_id TEXT NOT NULL, account TEXT NOT NULL, cursor INTEGER NOT NULL,
                revision INTEGER NOT NULL, PRIMARY KEY (server_id, account)) WITHOUT ROWID;
            INSERT INTO library_tracks VALUES ('server', 'user:alice', 'existing', X'\(payload)');
            INSERT INTO library_checkpoints VALUES ('server', 'user:alice', 14, 1);
            PRAGMA user_version = 1;
            """, at: file)

        let scope = LibraryScope(serverID: "server", username: "alice", deviceID: "device")
        let snapshot = try await database.snapshot(for: scope)
        XCTAssertEqual(snapshot, LibrarySnapshot(cursor: 14, tracks: [existing]))
        let prior = try await database.checkpoint(for: scope)
        let unchanged = LibraryPage(cursor: 14, full: false, tracks: [], deleted: [])
        try await database.apply(unchanged, etag: "validator", in: scope, expected: prior)
        let updated = try await database.checkpoint(for: scope)
        XCTAssertEqual(updated, LibraryCheckpoint(cursor: 14, etag: "validator", revision: 2))
    }

    func testUnsupportedSchemaIsReportedWithoutResettingTheDatabase() async throws {
        let (database, folder) = try temporaryDatabase()
        let file = folder.appending(path: "library.sqlite")
        try executeSQL("CREATE TABLE future(value TEXT); INSERT INTO future VALUES ('retained'); PRAGMA user_version = 99;",
                       at: file)
        let scope = LibraryScope(serverID: "server", username: "alice", deviceID: "device")
        do {
            _ = try await database.snapshot(for: scope)
            XCTFail("Expected a migration error")
        } catch let error as LibraryDatabaseError {
            XCTAssertEqual(error, .unsupportedSchema(99))
        }
        try executeSQL("UPDATE future SET value = 'still present';", at: file)
    }

    func testLibraryTransportUsesConditionalRequestAndDecodesTrackMetadata() async throws {
        let transport = ScriptedLibraryHTTP([
            .serverInfo,
            .init(body: """
                {"cursor":7,"full":true,"tracks":[{"id":"a","file":"a.mp3","title":"A","album_id":"album",
                "artist_id":"artist","track_number":4,"sample_rate":44100,"has_cover":true,"explicit":true}],"deleted":[]}
                """, headers: ["ETag": "\"v1\""]),
            .serverInfo, .init(status: 304)
        ])
        let api = LibraryAPIClient(transport: transport)
        let session = testSession()

        let result = try await api.fetch(since: 0, etag: nil, refresh: true, session: session)
        guard case let .page(page, etag) = result else { return XCTFail("Expected a library page") }
        XCTAssertEqual(etag, "\"v1\"")
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.albumID, "album")
        XCTAssertEqual(track.artistID, "artist")
        XCTAssertEqual(track.trackNumber, 4)
        XCTAssertEqual(track.sampleRate, 44_100)
        XCTAssertTrue(track.hasCover)
        XCTAssertTrue(track.isExplicit)

        let notModified = try await api.fetch(since: 7, etag: "\"v2\"", refresh: false, session: session)
        XCTAssertEqual(notModified, .unchanged)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/music/api/server/info", "/music/api/v1/library", "/music/api/server/info", "/music/api/v1/library"
        ])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(requests[1].url?.query, "since=0&refresh=true")
        XCTAssertEqual(requests[3].url?.query, "since=7")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"v2\"")
    }

    @MainActor
    func testSocketEventsCommitRefreshAndSigningOutCancelsPendingRefresh() async throws {
        let (database, _) = try temporaryDatabase()
        let session = testSession()
        let state = SessionState(session)
        let socketReady = expectation(description: "Socket opened")
        let socketStopped = expectation(description: "Socket stopped")
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let receivedRefresh = expectation(description: "Socket change fetched the next cursor")
        let receivedSecondRefresh = expectation(description: "Second change fetched the committed cursor")
        let policyRefresh = expectation(description: "Music policy changes trigger a verified info refresh")
        let feed = ScriptedLibraryFeed([
            .page(10, full: true, tracks: [track("before")]),
            .held(.page(LibraryPage(cursor: 11, full: false, tracks: [track("after")], deleted: []), etag: nil),
                  receivedRefresh, firstGate),
            .held(.page(LibraryPage(cursor: 12, full: false, tracks: [track("signed-out")], deleted: []), etag: nil),
                  receivedSecondRefresh, secondGate)
        ])
        let repository = LibraryRepository(database: database, feed: feed, session: { await state.current })
        let socket = TestLibrarySocket(ready: socketReady, stopped: socketStopped)
        let coordinator = LibrarySyncCoordinator(
            repository: repository, events: socket, sessionUpdates: { state.updates },
            verifySession: { _ in .active },
            didChangeMusicPolicy: { _ in policyRefresh.fulfill() }
        )

        let worker = Task { await coordinator.runWhileActive() }
        defer { worker.cancel() }
        await fulfillment(of: [socketReady], timeout: 3)
        XCTAssertEqual(LibraryLiveEvent.decode(.string(#"{"type":"library_changed"}"#)), .libraryChanged)
        XCTAssertEqual(LibraryLiveEvent.decode(.string(#"{"type":"playlists_changed"}"#)), .collectionsChanged)
        XCTAssertEqual(LibraryLiveEvent.decode(.string(#"{"type":"likes","count":3}"#)), .collectionsChanged)
        XCTAssertEqual(LibraryLiveEvent.decode(.string(#"{"type":"music_policy_changed"}"#)), .musicPolicyChanged)
        XCTAssertNil(LibraryLiveEvent.decode(.string(#"{"type":"other"}"#)))
        socket.continuation.yield(.musicPolicyChanged)
        await fulfillment(of: [policyRefresh], timeout: 3)
        socket.continuation.yield(.libraryChanged)
        await fulfillment(of: [receivedRefresh], timeout: 3)
        socket.continuation.yield(.libraryChanged)
        await firstGate.release()
        await fulfillment(of: [receivedSecondRefresh], timeout: 3)

        await state.set(nil)
        await secondGate.release()
        await fulfillment(of: [socketStopped], timeout: 3)
        worker.cancel()
        await worker.value
        let requests = await feed.requests
        XCTAssertEqual(requests.map(\.cursor), [0, 10, 11])
        let scope = LibraryScope(serverID: "server", username: "alice", deviceID: "device")
        let retained = try await database.snapshot(for: scope)
        XCTAssertEqual(retained, LibrarySnapshot(cursor: 11, tracks: [track("after"), track("before")]))
    }

    func testConnectionServicePublishesSuccessfulSessionChanges() async throws {
        let transport = ScriptedLibraryHTTP([
            .serverInfo,
            .init(body: """
                {"token":"fixture-token","device":{"id":"device"},"server":{"server_id":"server"},"user":{"username":"alice"}}
                """)
        ])
        let connection = ConnectionService(transport: transport, store: TestDeviceSessionStore())
        let updates = try await connection.sessionUpdates()
        var iterator = updates.makeAsyncIterator()
        guard case .some(.none) = await iterator.next() else { return XCTFail("Expected initial signed out state") }
        let target = try await connection.probe("https://example.test/music")
        let saved = try await connection.pair(code: "TEST-1234", at: target, deviceName: "iPhone")
        let updated = await iterator.next() ?? nil
        XCTAssertEqual(updated, saved)
        try await connection.signOut()
        guard case .some(.none) = await iterator.next() else { return XCTFail("Expected signed out state") }
    }

    private func temporaryDatabase() throws -> (LibraryDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return (LibraryDatabase(fileURL: folder.appending(path: "library.sqlite")), folder)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open(url.path, &handle)
        defer { if let handle { sqlite3_close(handle) } }
        guard opened == SQLITE_OK else { throw LibraryDatabaseError.sqlite(opened) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw LibraryDatabaseError.sqlite(result) }
    }
}

private func track(_ id: String, title: String? = nil) -> LibraryTrack {
    LibraryTrack(id: id, file: "\(id).mp3", title: title ?? id, artist: "", artists: [], album: "", albumArtist: "",
                 albumID: "", artistID: "", trackNumber: 0, year: "", duration: 0, codec: "mp3", bitrate: 0,
                 sampleRate: 0, channels: 0, size: 0, added: 0, hasCover: false, isExplicit: false, playlists: [])
}

private func testSession(serverID: String = "server", username: String = "alice", deviceID: String = "device") -> DeviceSession {
    DeviceSession(baseAddress: "https://example.test/music", serverID: serverID, serverName: "Server", deviceID: deviceID,
                  username: username, role: "user", token: "fixture-token", allowsInsecureHTTP: false)
}

private actor ScriptedLibraryFeed: LibraryFeedFetching {
    enum Step {
        case result(LibraryFeedResult)
        case held(LibraryFeedResult, XCTestExpectation, AsyncGate)
        case failure(APIError)

        static func page(
            _ cursor: Int64, full: Bool = false, tracks: [LibraryTrack] = [], deleted: [String] = [], etag: String? = nil
        ) -> Step {
            .result(.page(LibraryPage(cursor: cursor, full: full, tracks: tracks, deleted: deleted), etag: etag))
        }
    }

    struct Request {
        let cursor: Int64
        let etag: String?
        let refresh: Bool
    }

    private var steps: [Step]
    private(set) var requests: [Request] = []

    init(_ steps: [Step]) { self.steps = steps }

    func fetch(since cursor: Int64, etag: String?, refresh: Bool, session: DeviceSession) async throws -> LibraryFeedResult {
        requests.append(Request(cursor: cursor, etag: etag, refresh: refresh))
        guard !steps.isEmpty else { throw APIError.invalidResponse }
        switch steps.removeFirst() {
        case let .result(result): return result
        case let .held(result, started, gate):
            started.fulfill()
            await gate.wait()
            return result
        case let .failure(error): throw error
        }
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RecordedWaits {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}

private actor SessionState {
    private(set) var current: DeviceSession?
    let updates: AsyncStream<DeviceSession?>
    private let continuation: AsyncStream<DeviceSession?>.Continuation

    init(_ session: DeviceSession?) {
        current = session
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(session)
    }

    func set(_ session: DeviceSession?) {
        current = session
        continuation.yield(session)
    }
}

private struct TestLibrarySocket: LibraryEventStreaming {
    private let stream: AsyncThrowingStream<LibraryLiveEvent, Error>
    let continuation: AsyncThrowingStream<LibraryLiveEvent, Error>.Continuation
    let ready: XCTestExpectation

    init(ready: XCTestExpectation, stopped: XCTestExpectation) {
        (stream, continuation) = AsyncThrowingStream.makeStream()
        self.ready = ready
        continuation.onTermination = { _ in stopped.fulfill() }
    }

    func events(for session: DeviceSession) async throws -> AsyncThrowingStream<LibraryLiveEvent, Error> {
        ready.fulfill()
        return stream
    }
}

private actor ScriptedLibraryHTTP: HTTPDataLoading {
    struct Response {
        var body = ""
        var status = 200
        var headers: [String: String] = [:]

        static let serverInfo = Response(body: #"{"product":"Downtify","api_version":1,"server_id":"server"}"#)
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty, let url = request.url else { throw APIError.invalidResponse }
        let next = responses.removeFirst()
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil,
                                                    headerFields: next.headers))
        return (Data(next.body.utf8), response)
    }
}

private final class TestDeviceSessionStore: DeviceSessionStoring {
    private var session: DeviceSession?

    func load() throws -> DeviceSession? { session }
    func save(_ session: DeviceSession) throws { self.session = session }
    func clear() throws { session = nil }
}
