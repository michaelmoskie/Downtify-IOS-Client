import XCTest
@testable import Downtify

@MainActor
final class LibraryPresentationModelTests: XCTestCase {
    func testServerDownloadReconciliationUsesJobStatusAndActiveJobsTakePrecedence() throws {
        func jobs(_ statuses: [String]) throws -> [ServerDownloadQueue.Job] {
            let json = statuses.map { "{\"song\":{\"id\":\"song\"},\"status\":\"\($0)\"}" }.joined(separator: ",")
            return try JSONDecoder().decode([ServerDownloadQueue.Job].self, from: Data("[\(json)]".utf8))
        }
        XCTAssertEqual(ServerDownloadPresentationModel.reconciledState(for: try jobs(["running"])), .queued(jobID: "song"))
        XCTAssertEqual(ServerDownloadPresentationModel.reconciledState(for: try jobs(["done"])), .accepted)
        XCTAssertEqual(ServerDownloadPresentationModel.reconciledState(for: try jobs(["failed"])), .failed("The server download failed."))
        XCTAssertEqual(ServerDownloadPresentationModel.reconciledState(for: try jobs(["unexpected"])), .outcomeUnknown)
        XCTAssertEqual(ServerDownloadPresentationModel.reconciledState(for: try jobs(["failed", "running"])), .queued(jobID: "song"))
        XCTAssertEqual(ServerDownloadPresentationModel.reconciledState(for: []), nil)
    }

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

    func testLibraryOnlyDiscoverKeepsArtistsAndDisablesCollections() async throws {
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = CatalogPresentationModel(api: CatalogServingStub(libraryOnly: true, discoverPartial: true), sessionUpdates: { updates })
        model.start()
        continuation.yield(makeSession())
        await waitUntil { model.policyState == .ready }
        model.loadDiscover(library: [], albums: [], playlistNames: [], playlistIDs: [], shown: [])
        await waitUntil { if case .partial = model.discoverArtistsState { return true }; return false }
        if case .unavailable = model.deezerCollectionsState {} else { XCTFail("Expected Deezer unavailable") }
        if case .unavailable = model.spotifyCollectionsState {} else { XCTFail("Expected Spotify unavailable") }
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
        XCTAssertNil(playlist.manual)
        XCTAssertNil(playlist.canEditTracks)
        XCTAssertNil(playlist.sharedWith)
        XCTAssertNil(playlist.editors)
        XCTAssertEqual(catalog.tracks(in: .playlist("stable"), likedIDs: [], playlist: playlist).map(\.id),
                       ["id-2", "id-1", "id-2"])
        XCTAssertEqual(catalog.tracks(in: .liked, likedIDs: ["id-2", "gone", "id-1"], playlist: nil).map(\.id),
                       ["id-2", "id-1"])
        let numbered = LibraryCatalog([makeTrack("z", albumID: "album", trackNumber: 1),
                                       makeTrack("a", albumID: "album", trackNumber: 2)])
        XCTAssertEqual(numbered.tracks(in: .album("album"), likedIDs: [], playlist: nil).map(\.id), ["z", "a"])
    }

    func testPlaylistOccurrencesPreserveDuplicatesAndUnresolvedIDs() throws {
        let playlist = try JSONDecoder().decode(LibraryPlaylist.self, from: Data(
            #"{"name":"stable","track_ids":["known","missing","known"]}"#.utf8
        ))
        let catalog = LibraryCatalog([makeTrack("known")])

        let rows = catalog.playlistOccurrences(playlist)

        XCTAssertEqual(rows.map(\.occurrence.trackID), ["known", "missing", "known"])
        XCTAssertEqual(rows.map(\.occurrence.position), [0, 1, 2])
        XCTAssertEqual(rows[0].track?.id, "known")
        XCTAssertNil(rows[1].track)
        XCTAssertEqual(rows[2].track?.id, "known")
        XCTAssertNotEqual(rows[0].id, rows[2].id)
    }

    func testPlaylistCompleteOrderRequiresEveryOccurrenceIncludingUnresolvedIDs() throws {
        let trackIDs = ["known", "missing", "known"]
        let original = PlaylistTrackOccurrence.ordered(trackIDs)
        let reordered = [original[2], original[1], original[0]]

        XCTAssertEqual(PlaylistTrackOccurrence.completeOrder(reordered, matching: trackIDs),
                       ["known", "missing", "known"])
        XCTAssertNil(PlaylistTrackOccurrence.completeOrder([original[0], original[2]], matching: trackIDs))
        XCTAssertNil(PlaylistTrackOccurrence.completeOrder(
            [original[0], original[1], PlaylistTrackOccurrence(trackID: "extra", position: 3)],
            matching: trackIDs
        ))
    }

    func testPlaylistListingDecodesManualAndPermissionFieldsWhenAvailable() throws {
        let playlist = try JSONDecoder().decode(LibraryPlaylist.self, from: Data(
            #"{"name":"shared","track_ids":["song","song"],"manual":true,"mine":false,"can_edit_tracks":true,"shared_with":["listener"],"editors":["listener"]}"#.utf8
        ))

        XCTAssertEqual(playlist.manual, true)
        XCTAssertEqual(playlist.mine, false)
        XCTAssertEqual(playlist.canEditTracks, true)
        XCTAssertEqual(playlist.sharedWith, ["listener"])
        XCTAssertEqual(playlist.editors, ["listener"])
        XCTAssertEqual(playlist.trackIDs, ["song", "song"])
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
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.pendingActions.count, 1)
        XCTAssertFalse(model.effectiveLike("cached"))
        XCTAssertEqual(model.likedIDs, ["cached"])

        continuation.yield(second)
        await waitUntil { model.playlistState == .unavailable && model.playlists == nil }
        XCTAssertNil(model.likedIDs)
        XCTAssertTrue(model.recents.isEmpty)
        continuation.finish()
    }

    func testQueuedActionsSurviveRestartAndDrainInOrder() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let feed = PendingActionFeed()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        var model: LibraryCollectionsModel? = LibraryCollectionsModel(api: feed, database: database, sessionUpdates: { updates })
        model?.start()
        continuation.yield(session)
        await waitUntil { model?.likesState == .ready && model?.playlistState == .ready }
        await model?.toggleLike(makeTrack("song"))
        await model?.toggleLike(makeTrack("song"))
        await model?.toggleFavorite("Mix")
        XCTAssertEqual(model?.pendingActions.map(\.desiredValue), [true, false, true])
        XCTAssertFalse(model?.effectiveLike("song") ?? true)
        XCTAssertTrue(model?.effectiveFavorite(try XCTUnwrap(model?.playlist(named: "Mix"))) ?? false)
        model = nil
        continuation.finish()

        let (restoredUpdates, restoredContinuation) = AsyncStream<DeviceSession?>.makeStream()
        let restored = LibraryCollectionsModel(api: feed, database: database, sessionUpdates: { restoredUpdates })
        restored.start()
        restoredContinuation.yield(session)
        await waitUntil { restored.pendingActions.count == 3 && restored.likesState == .ready }
        XCTAssertEqual(restored.pendingActions.map(\.desiredValue), [true, false, true])
        restored.setActionsPathAvailable(true)
        restored.setActionsActive(true)
        await waitUntil { restored.pendingActions.allSatisfy { $0.status == .sent } }
        let writes = await feed.recordedWrites()
        XCTAssertEqual(writes, ["like:song:true", "like:song:false", "favorite:Mix:true"])
        restoredContinuation.finish()
    }

    func testChangedFavoriteFailsAndLaterActionContinues() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = PendingActionFeed()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: feed, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(makeSession())
        await waitUntil { model.likesState == .ready && model.playlistState == .ready }
        await model.toggleFavorite("Mix")
        await model.toggleLike(makeTrack("song"))
        await feed.removePlaylist()
        model.setActionsPathAvailable(true)
        model.setActionsActive(true)
        await waitUntil { model.pendingActions.count == 2 && model.pendingActions[1].status == .sent }
        XCTAssertEqual(model.pendingActions.first?.status, .failed)
        XCTAssertNotNil(model.pendingActions.first?.failure)
        let writes = await feed.recordedWrites()
        XCTAssertEqual(writes, ["like:song:true"])
        let failed = try XCTUnwrap(model.pendingActions.first)
        await model.dismissAction(failed.id)
        XCTAssertEqual(model.pendingActions.count, 1)
        continuation.finish()
    }

    func testQueueRetryClassificationAndBackoff() {
        for attempt in 1...4 {
            XCTAssertEqual(LibraryCollectionsModel.retryDelay(for: URLError(.timedOut), attempt: attempt),
                           pow(2.0, Double(attempt)))
        }
        XCTAssertEqual(LibraryCollectionsModel.retryDelay(for: APIError.httpStatus(429, retryAfter: 30), attempt: 1), 30)
        XCTAssertEqual(LibraryCollectionsModel.retryDelay(for: APIError.httpStatus(503, retryAfter: 1), attempt: 2), 4)
        XCTAssertNil(LibraryCollectionsModel.retryDelay(for: APIError.httpStatus(403, retryAfter: nil), attempt: 1))
        XCTAssertNil(LibraryCollectionsModel.retryDelay(for: URLError(.userAuthenticationRequired), attempt: 1))
    }

    func testRetryPersistsBackoffAndPreservesIntentAfterLostAcknowledgment() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = PendingActionFeed()
        await feed.loseNextAcknowledgment()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: feed, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(makeSession())
        await waitUntil { model.likesState == .ready }
        await model.toggleLike(makeTrack("song"))
        model.setActionsPathAvailable(true)
        model.setActionsActive(true)
        await waitUntil { model.pendingActions.first?.attempts == 1 }
        let queued = try XCTUnwrap(model.pendingActions.first)
        XCTAssertEqual(queued.status, .queued)
        XCTAssertGreaterThan(try XCTUnwrap(queued.nextAttempt).timeIntervalSinceNow, 1)
        let deadline = ContinuousClock.now + .seconds(4)
        while model.pendingActions.first?.status != .sent && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.pendingActions.first?.status, .sent)
        let writes = await feed.recordedWrites()
        XCTAssertEqual(writes, ["like:song:true", "like:song:true"])
        continuation.finish()
    }

    func testInFlightResultDoesNotUpdateReplacementSession() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = PendingActionFeed()
        await feed.pauseNextWrite()
        let first = makeSession(server: "one")
        let second = makeSession(server: "two")
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: feed, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(first)
        await waitUntil { model.likesState == .ready }
        await model.toggleLike(makeTrack("song"))
        model.setActionsPathAvailable(true)
        model.setActionsActive(true)
        await waitUntilAsync { await feed.isWaiting() }
        continuation.yield(second)
        await waitUntil { model.pendingActions.isEmpty && model.likesState == .ready }
        await feed.resumeWrite()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.pendingActions.isEmpty)
        XCTAssertFalse(model.effectiveLike("song"))
        let scope = LibraryScope(serverID: first.serverID, username: first.username, deviceID: first.deviceID)
        let stored = try await database.pendingActions(in: scope, deviceID: first.deviceID)
        XCTAssertTrue(stored.isEmpty)
        continuation.finish()
    }

    func testSignOutDiscardsQueuedActions() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = PendingActionFeed()
        let session = makeSession()
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: feed, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.likesState == .ready }
        await model.toggleLike(makeTrack("song"))
        continuation.yield(nil)
        await waitUntil { model.pendingActions.isEmpty && model.likedIDs == nil }
        let scope = LibraryScope(serverID: session.serverID, username: session.username, deviceID: session.deviceID)
        let stored = try await database.pendingActions(in: scope, deviceID: session.deviceID)
        XCTAssertTrue(stored.isEmpty)
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
        model.setActionsActive(true)
        model.setActionsPathAvailable(true)
        XCTAssertEqual(model.playlist(named: "stable")?.title, "Display label")
        await model.toggleFavorite("legacy")
        await model.toggleFavorite("stable")
        await model.toggleLike(makeTrack("song"))
        XCTAssertTrue(model.effectiveLike("song"))
        await model.toggleLike(makeTrack("song"))
        XCTAssertFalse(model.effectiveLike("song"))
        await waitUntil { model.pendingActions.count == 3 && model.pendingActions.allSatisfy { $0.status == .sent } }
        XCTAssertEqual(model.playlist(named: "stable")?.favorite, true)
        XCTAssertEqual(model.likedIDs, ["prior"])
        let writes = await transport.writes
        XCTAssertEqual(writes, ["favorite:stable:true", "like:song:true", "like:song:false"])
        continuation.finish()
    }

    func testPlaylistMutationsRefreshAuthoritativeStateAndPreserveOccurrenceArguments() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let api = PlaylistMutationFeed(playlists: [playlist("Road", ids: ["a", "b", "a"])])
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: api, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.playlistState == .ready }

        await model.createPlaylist(name: "New")
        XCTAssertEqual(model.playlist(named: "New")?.manual, true)
        await model.renamePlaylist(name: "Road", to: "Drive")
        XCTAssertNotNil(model.playlist(named: "Drive"))
        await model.addTracks(["c"], to: "Drive", allowDuplicates: true)
        XCTAssertEqual(model.playlist(named: "Drive")?.trackIDs, ["a", "b", "a", "c"])
        await model.removePlaylistOccurrence(trackID: "a", occurrence: 1, from: "Drive")
        XCTAssertEqual(model.playlist(named: "Drive")?.trackIDs, ["a", "b", "c"])
        await model.removeTracks(["a"], from: "Drive")
        XCTAssertEqual(model.playlist(named: "Drive")?.trackIDs, ["b", "c"])
        await model.reorderPlaylist("Drive", trackIDs: ["c", "b"])
        XCTAssertEqual(model.playlist(named: "Drive")?.trackIDs, ["c", "b"])
        XCTAssertNil(model.playlistMutationError)

        let writes = await api.recordedWrites()
        XCTAssertEqual(writes, [
            "create:New",
            "rename:Road:Drive",
            "edit:Drive:add=c:remove=-:remove_entries=-:allow_duplicates=true",
            "edit:Drive:add=-:remove=-:remove_entries=a@1:allow_duplicates=-",
            "edit:Drive:add=-:remove=a:remove_entries=-:allow_duplicates=-",
            "reorder:Drive:c,b"
        ])
        let refreshes = await api.playlistRefreshCount()
        XCTAssertGreaterThanOrEqual(refreshes, 7)
        continuation.finish()
    }

    func testPlaylistMutationErrorsMapAndReorderConflictRefreshesWithoutReplay() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let api = PlaylistMutationFeed(playlists: [playlist("Road", ids: ["a", "b"])])
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: api, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.playlistState == .ready }

        let failures: [(Int, LibraryCollectionsModel.PlaylistMutationError)] = [
            (400, .invalidRequest), (403, .permissionDenied), (404, .notFound),
            (503, .libraryIndexUnavailable)
        ]
        for (status, expected) in failures {
            await api.failNextWrite(status: status)
            await model.addTracks(["c"], to: "Road")
            XCTAssertEqual(model.playlistMutationError, expected)
            model.clearPlaylistMutationError()
        }

        await api.prepareConflict(with: playlist("Road", ids: ["a", "b", "c"]))
        await model.reorderPlaylist("Road", trackIDs: ["b", "a"])
        XCTAssertEqual(model.playlistMutationError, .conflictRequiresReview)
        XCTAssertEqual(model.playlist(named: "Road")?.trackIDs, ["a", "b", "c"])
        let writes = await api.recordedWrites()
        XCTAssertEqual(writes.filter { $0.hasPrefix("reorder:") }, ["reorder:Road:b,a"])
        continuation.finish()
    }

    func testCanonicalRenameAndFailedConflictRefresh() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = PlaylistMutationFeed(playlists: [playlist("Road", ids: ["a", "b"])])
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: api, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(makeSession())
        await waitUntil { model.playlistState == .ready }
        model.record(.playlist("Road"))
        await api.setCanonicalRename("Canonical")
        await api.pauseNextRefresh()
        let rename = Task { await model.renamePlaylist(name: "Road", to: " Requested ") }
        await waitUntilAsync { await api.refreshIsWaiting() }
        XCTAssertEqual(model.playlist(named: "Road")?.name, "Canonical")
        XCTAssertEqual(model.recents, [.playlist("Canonical")])
        await api.releaseRefresh()
        await rename.value
        await api.prepareConflict(with: playlist("Canonical", ids: ["a", "b", "c"]))
        await api.setRefreshFailure(true)
        await model.reorderPlaylist("Canonical", trackIDs: ["b", "a"])
        XCTAssertEqual(model.playlistMutationError, .conflictRefreshFailed)
        await api.setRefreshFailure(false)
        await model.refreshPlaylistAfterConflict()
        XCTAssertEqual(model.playlistMutationError, .conflictRequiresReview)
        XCTAssertEqual(model.playlist(named: "Canonical")?.trackIDs, ["a", "b", "c"])
        continuation.finish()
    }

    func testRenameUpdatesRecentAndOpenPlaylistReferences() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let api = PlaylistMutationFeed(playlists: [playlist("Road", ids: ["a"])])
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: api, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(session)
        await waitUntil { model.playlistState == .ready }
        model.record(.playlist("Road"))

        await model.renamePlaylist(name: "Road", to: "Drive")

        XCTAssertEqual(model.recents, [.playlist("Drive")])
        XCTAssertEqual(model.playlist(named: "Road")?.name, "Drive")
        XCTAssertEqual(model.playlist(named: "Drive")?.name, "Drive")
        continuation.finish()
    }

    func testStaleCapabilityAndMutationResponsesCannotCrossSessions() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = makeSession(server: "one")
        let second = makeSession(server: "two")
        let api = PlaylistMutationFeed(playlistsByServer: [
            "one": [playlist("First", ids: ["a"])],
            "two": [playlist("Second", ids: ["b"])]
        ], capabilities: ["one": false, "two": true])
        await api.pauseCapability(for: "one")
        let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
        let model = LibraryCollectionsModel(api: api, database: database, sessionUpdates: { updates })
        model.start()
        continuation.yield(first)
        await waitUntil { model.playlistState == .ready }
        await waitUntilAsync { await api.capabilityIsWaiting(for: "one") }

        continuation.yield(second)
        await waitUntil { model.playlist(named: "Second") != nil && model.supportsPlaylistEditing }
        await api.releaseCapability(for: "one")
        await waitUntilAsync { !(await api.capabilityIsWaiting(for: "one")) }
        XCTAssertTrue(model.supportsPlaylistEditing)

        await api.pauseNextWrite()
        let staleMutation = Task { await model.createPlaylist(name: "Stale") }
        await waitUntilAsync { await api.writeIsWaiting() }
        continuation.yield(first)
        await waitUntil { model.playlist(named: "First") != nil && !model.mutationBusy }
        await api.releaseWrite()
        await staleMutation.value
        XCTAssertEqual(model.playlists?.map(\.name), ["First"])
        XCTAssertFalse(model.playlists?.contains(where: { $0.name == "Stale" }) ?? true)
        continuation.finish()
    }

    func testPlaylistChangeNotificationRefreshesOpenCollectionAndCoalescesWithMutation() async throws {
        let (database, folder) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession()
        let api = PlaylistMutationFeed(playlists: [playlist("Road", ids: ["a"])])
        let (collectionUpdates, collectionContinuation) = AsyncStream<DeviceSession?>.makeStream()
        let (coordinatorUpdates, coordinatorContinuation) = AsyncStream<DeviceSession?>.makeStream()
        let collections = LibraryCollectionsModel(api: api, database: database, sessionUpdates: { collectionUpdates })
        collections.start()
        collectionContinuation.yield(session)
        coordinatorContinuation.yield(session)
        await waitUntil { collections.playlistState == .ready }

        let (events, eventContinuation) = AsyncThrowingStream<LibraryLiveEvent, Error>.makeStream()
        let socketReady = expectation(description: "Collections event stream opened")
        let deferredNotificationHandled = expectation(description: "Notification was handled during the mutation")
        let notificationCallbackCount = NotificationCallbackCount()
        let coordinator = LibrarySyncCoordinator(
            repository: LibraryRepository(database: database, feed: Feed([]), session: { session }),
            events: TestCollectionsSocket(stream: events, ready: socketReady),
            sessionUpdates: { coordinatorUpdates },
            verifySession: { _ in .active },
            didChangeCollections: { expectedSession in
                await collections.refresh(for: expectedSession)
                if await notificationCallbackCount.increment() == 2 {
                    deferredNotificationHandled.fulfill()
                }
            }
        )
        let worker = Task { await coordinator.runWhileActive() }
        await fulfillment(of: [socketReady], timeout: 3)
        eventContinuation.yield(.connected)
        await waitUntilAsync { await api.playlistRefreshCount() >= 2 }

        await api.replacePlaylists([playlist("Road", ids: ["a", "from-notification"])])
        eventContinuation.yield(.collectionsChanged)
        await waitUntil { collections.playlist(named: "Road")?.trackIDs == ["a", "from-notification"] }
        XCTAssertEqual(collections.playlist(named: "Road")?.trackIDs, ["a", "from-notification"])

        await api.pauseNextWrite()
        let mutation = Task { await collections.addTracks(["after-notification"], to: "Road") }
        await waitUntilAsync { await api.writeIsWaiting() }
        await api.replacePlaylists([playlist("Road", ids: ["a", "remote-change"])])
        eventContinuation.yield(.collectionsChanged)
        await fulfillment(of: [deferredNotificationHandled], timeout: 3)
        await api.releaseWrite()
        await mutation.value

        XCTAssertEqual(collections.playlist(named: "Road")?.trackIDs, ["a", "remote-change", "after-notification"])
        XCTAssertNil(collections.playlistMutationError)

        collectionContinuation.finish()
        coordinatorContinuation.finish()
        eventContinuation.finish()
        worker.cancel()
        await worker.value
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

    private func waitUntilAsync(_ condition: @escaping () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
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

private struct TestCollectionsSocket: LibraryEventStreaming {
    let stream: AsyncThrowingStream<LibraryLiveEvent, Error>
    let ready: XCTestExpectation

    func events(for session: DeviceSession) async throws -> AsyncThrowingStream<LibraryLiveEvent, Error> {
        ready.fulfill()
        return stream
    }
}

private actor NotificationCallbackCount {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
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


private actor PendingActionFeed: LibraryCollectionsFetching {
    private var available = true
    private var liked = false
    private var favorite = false
    private var writes: [String] = []
    private var loseAcknowledgment = false
    private var pauseWrite = false
    private var waiting = false
    private var writeContinuation: CheckedContinuation<Void, Never>?

    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist] {
        guard available else { return [] }
        let json = #"[{"name":"Mix","owner":"owner","manual":true,"favorite":\#(favorite),"track_ids":[]}]"#
        return try JSONDecoder().decode([LibraryPlaylist].self, from: Data(json.utf8))
    }
    func likes(for session: DeviceSession) async throws -> [String] { liked ? ["song"] : [] }
    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws {
        if pauseWrite {
            pauseWrite = false
            waiting = true
            await withCheckedContinuation { writeContinuation = $0 }
            waiting = false
            try Task.checkCancellation()
        }
        self.liked = liked
        writes.append("like:\(trackID):\(liked)")
        if loseAcknowledgment {
            loseAcknowledgment = false
            throw URLError(.networkConnectionLost)
        }
    }
    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws {
        self.favorite = favorite
        writes.append("favorite:\(name):\(favorite)")
    }
    func removePlaylist() { available = false }
    func loseNextAcknowledgment() { loseAcknowledgment = true }
    func pauseNextWrite() { pauseWrite = true }
    func isWaiting() -> Bool { waiting }
    func resumeWrite() { writeContinuation?.resume(); writeContinuation = nil }
    func recordedWrites() -> [String] { writes }
}

private struct CollectionsFeed: LibraryCollectionsFetching {
    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist] { throw APIError.transportFailure }
    func likes(for session: DeviceSession) async throws -> [String] { throw APIError.transportFailure }
    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws { throw APIError.transportFailure }
    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws { throw APIError.transportFailure }
}

private actor PlaylistMutationFeed: LibraryCollectionsFetching {
    private var playlistsByServer: [String: [LibraryPlaylist]]
    private let capabilities: [String: Bool]
    private var writes: [String] = []
    private var refreshCount = 0
    private var failRefresh = false
    private var pauseRefresh = false
    private var refreshWaiting = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var canonicalRename: String?
    private var nextWriteStatus: Int?
    private var conflictPlaylists: [String: LibraryPlaylist] = [:]
    private var pausedCapabilityIDs: Set<String> = []
    private var capabilityContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var capabilityWaiters: Set<String> = []
    private var pauseWrite = false
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeWaiting = false

    init(playlists: [LibraryPlaylist]) {
        self.playlistsByServer = ["server": playlists]
        self.capabilities = [:]
    }

    init(playlistsByServer: [String: [LibraryPlaylist]], capabilities: [String: Bool]) {
        self.playlistsByServer = playlistsByServer
        self.capabilities = capabilities
    }

    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist] {
        refreshCount += 1
        if pauseRefresh {
            pauseRefresh = false
            refreshWaiting = true
            await withCheckedContinuation { refreshContinuation = $0 }
            refreshWaiting = false
        }
        if failRefresh { throw APIError.transportFailure }
        return playlistsByServer[session.serverID] ?? []
    }

    func likes(for session: DeviceSession) async throws -> [String] { [] }
    func supportsPlaylistEditing(for session: DeviceSession) async throws -> Bool {
        if pausedCapabilityIDs.contains(session.serverID) {
            capabilityWaiters.insert(session.serverID)
            await withCheckedContinuation { capabilityContinuations[session.serverID] = $0 }
            capabilityWaiters.remove(session.serverID)
        }
        return capabilities[session.serverID] ?? false
    }
    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws {}
    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws {}

    func createPlaylist(name: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO {
        writes.append("create:\(name)")
        try await pauseOrFail()
        playlistsByServer[session.serverID, default: []].append(playlist(name, ids: []))
        return response(name, ids: [])
    }

    func renamePlaylist(name: String, to newName: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO {
        writes.append("rename:\(name):\(newName)")
        try await pauseOrFail()
        let canonical = canonicalRename ?? newName
        replacePlaylist(named: name, with: canonical, session: session)
        return response(canonical, ids: playlistsByServer[session.serverID]?.first(where: { $0.name == canonical })?.trackIDs ?? [], previous: name)
    }

    func editPlaylistTracks(
        name: String, add: [String]?, remove: [String]?,
        removeEntries: [PlaylistTrackEditsRequestDTO.RemovalEntry]?, allowDuplicates: Bool?, session: DeviceSession
    ) async throws -> PlaylistMutationResponseDTO {
        let entries = removeEntries.map { $0.map { "\($0.trackID)@\($0.occurrence)" }.joined(separator: ",") } ?? "-"
        let additions = add.map { $0.joined(separator: ",") } ?? "-"
        let removals = remove.map { $0.joined(separator: ",") } ?? "-"
        let duplicateFlag = allowDuplicates.map { $0 ? "true" : "false" } ?? "-"
        writes.append("edit:\(name):add=\(additions):remove=\(removals):remove_entries=\(entries):allow_duplicates=\(duplicateFlag)")
        try await pauseOrFail()
        guard let index = playlistsByServer[session.serverID]?.firstIndex(where: { $0.name == name }),
              let current = playlistsByServer[session.serverID]?[index] else { throw APIError.httpStatus(404, retryAfter: nil) }
        var ids = current.trackIDs
        for id in add ?? [] where allowDuplicates == true || !ids.contains(id) { ids.append(id) }
        for id in remove ?? [] { ids.removeAll { $0 == id } }
        for entry in (removeEntries ?? []).reversed() {
            let positions = ids.indices.filter { ids[$0] == entry.trackID }
            if entry.occurrence < positions.count { ids.remove(at: positions[entry.occurrence]) }
        }
        playlistsByServer[session.serverID]?[index] = playlist(name, ids: ids)
        return response(name, ids: ids)
    }

    func reorderPlaylist(name: String, trackIDs: [String], session: DeviceSession) async throws -> PlaylistMutationResponseDTO {
        writes.append("reorder:\(name):\(trackIDs.joined(separator: ","))")
        try await pauseOrFail()
        if let conflict = conflictPlaylists.removeValue(forKey: session.serverID) {
            if let index = playlistsByServer[session.serverID]?.firstIndex(where: { $0.name == name }) {
                playlistsByServer[session.serverID]?[index] = conflict
            }
            throw APIError.httpStatus(409, retryAfter: nil)
        }
        guard let index = playlistsByServer[session.serverID]?.firstIndex(where: { $0.name == name }) else { throw APIError.httpStatus(404, retryAfter: nil) }
        playlistsByServer[session.serverID]?[index] = playlist(name, ids: trackIDs)
        return response(name, ids: trackIDs)
    }

    private func response(_ name: String, ids: [String], previous: String? = nil) -> PlaylistMutationResponseDTO {
        PlaylistMutationResponseDTO(name: name, manual: true, count: ids.count, trackIDs: ids, previous: previous, added: nil, removed: nil, already: nil)
    }

    func pauseNextRefresh() { pauseRefresh = true }
    func refreshIsWaiting() -> Bool { refreshWaiting }
    func releaseRefresh() { refreshContinuation?.resume(); refreshContinuation = nil }
    func setRefreshFailure(_ fail: Bool) { failRefresh = fail }
    func setCanonicalRename(_ name: String) { canonicalRename = name }
    func failNextWrite(status: Int) { nextWriteStatus = status }
    func prepareConflict(with playlist: LibraryPlaylist, serverID: String = "server") {
        conflictPlaylists[serverID] = playlist
    }
    func recordedWrites() -> [String] { writes }
    func playlistRefreshCount() -> Int { refreshCount }
    func pauseCapability(for serverID: String) {
        pausedCapabilityIDs.insert(serverID)
    }
    func capabilityIsWaiting(for serverID: String) -> Bool { capabilityWaiters.contains(serverID) }
    func releaseCapability(for serverID: String) {
        pausedCapabilityIDs.remove(serverID)
        capabilityContinuations.removeValue(forKey: serverID)?.resume()
    }
    func pauseNextWrite() { pauseWrite = true }
    func writeIsWaiting() -> Bool { writeWaiting }
    func releaseWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }

    func replacePlaylists(_ playlists: [LibraryPlaylist], serverID: String = "server") {
        playlistsByServer[serverID] = playlists
    }

    private func pauseOrFail() async throws {
        if pauseWrite {
            pauseWrite = false
            writeWaiting = true
            await withCheckedContinuation { writeContinuation = $0 }
            writeWaiting = false
        }
        if let status = nextWriteStatus {
            nextWriteStatus = nil
            throw APIError.httpStatus(status, retryAfter: nil)
        }
    }

    private func replacePlaylist(named oldName: String, with newName: String, session: DeviceSession) {
        guard let index = playlistsByServer[session.serverID]?.firstIndex(where: { $0.name == oldName }),
              let current = playlistsByServer[session.serverID]?[index] else { return }
        playlistsByServer[session.serverID]?[index] = playlist(newName, ids: current.trackIDs)
    }
}

private func playlist(_ name: String, ids: [String]) -> LibraryPlaylist {
    let trackIDs = ids.map { "\"\($0)\"" }.joined(separator: ",")
    let data = Data("{\"name\":\"\(name)\",\"track_ids\":[\(trackIDs)],\"manual\":true,\"mine\":true,\"can_edit_tracks\":true}".utf8)
    return try! JSONDecoder().decode(LibraryPlaylist.self, from: data)
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
