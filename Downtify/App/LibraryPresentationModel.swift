import Combine
import Foundation

enum LibraryTrackOrdering {
    static func sorted(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        tracks.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    static func matching(_ tracks: [LibraryTrack], query: String) -> [LibraryTrack] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) ||
                $0.album.localizedStandardContains(query)
        }
    }
}

@MainActor
final class LibraryPresentationModel: ObservableObject {
    enum State: Equatable {
        case loading
        case empty
        case ready
        case refreshing
        case cachedError(String)
        case storageFailure(String)
    }

    @Published private(set) var tracks: [LibraryTrack] = [] {
        didSet {
            catalog = LibraryCatalog(tracks)
            sortedSongs.removeAll()
            latestAlbums = Array(LibrarySort.recentlyAdded.ordered(Array(catalog.albumsByID.values),
                                                                  descending: true).prefix(12))
        }
    }
    private(set) var catalog = LibraryCatalog([])
    private(set) var latestAlbums: [LibraryBrowseEntry] = []
    private var sortedSongs: [SongOrder: [LibraryTrack]] = [:]

    private struct SongOrder: Hashable {
        let sort: LibrarySort
        let descending: Bool
    }

    func songs(sort: LibrarySort, descending: Bool, query: String) -> [LibraryTrack] {
        let order = SongOrder(sort: sort, descending: descending)
        let sorted = sortedSongs[order] ?? sort.orderedTracks(tracks, descending: descending)
        sortedSongs[order] = sorted
        return LibraryTrackOrdering.matching(sorted, query: query)
    }
    @Published private(set) var state: State = .loading

    private let repository: LibraryRepository
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private var observation: Task<Void, Never>?
    private var session: DeviceSession?
    private var generation = 0

    init(repository: LibraryRepository, sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>) {
        self.repository = repository
        self.sessionUpdates = sessionUpdates
    }

    deinit { observation?.cancel() }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                for await session in try await sessionUpdates() {
                    guard !Task.isCancelled else { return }
                    await changeSession(to: session)
                }
            } catch {
                state = .storageFailure("The saved library could not be loaded.")
            }
        }
    }

    func refresh() async {
        guard let session else { return }
        let request = generation
        state = tracks.isEmpty ? .loading : .refreshing
        do {
            _ = try await repository.sync(for: session, refresh: true)
            guard request == generation, self.session == session else { return }
            await loadSnapshot(for: session, generation: request, clearRefreshError: true)
        } catch LibrarySyncError.sessionChanged {
            return
        } catch {
            guard request == generation, self.session == session else { return }
            if case .storageFailure = state { return }
            if (error as? APIError) == .transportFailure {
                state = .cachedError("Could not reach the server.")
            } else {
                state = .cachedError("Library refresh failed.")
            }
        }
    }

    func syncDidUpdate(for session: DeviceSession) async {
        guard self.session == session else { return }
        await loadSnapshot(for: session, generation: generation, clearRefreshError: true)
    }

    func syncDidFail(for session: DeviceSession, message: String) {
        guard self.session == session else { return }
        if case .storageFailure = state { return }
        state = .cachedError(message)
    }

    private func changeSession(to newSession: DeviceSession?) async {
        generation += 1
        let request = generation
        session = newSession
        tracks = []
        guard let newSession else { state = .empty; return }
        state = .loading
        await loadSnapshot(for: newSession, generation: request)
    }

    private func loadSnapshot(
        for session: DeviceSession, generation request: Int, clearRefreshError: Bool = false
    ) async {
        do {
            let snapshot = try await repository.snapshot(for: session)
            guard request == generation, self.session == session else { return }
            if tracks != snapshot.tracks { tracks = snapshot.tracks }
            if !clearRefreshError, case .cachedError = state { return }
            if snapshot.cursor == nil && snapshot.tracks.isEmpty {
                state = .loading
            } else {
                state = snapshot.tracks.isEmpty ? .empty : .ready
            }
        } catch LibrarySyncError.sessionChanged {
            return
        } catch {
            guard request == generation, self.session == session else { return }
            state = .storageFailure("Saved library storage is unavailable.")
        }
    }
}

@MainActor
final class LibraryCollectionsModel: ObservableObject {
    enum State: Equatable { case loading, ready, unavailable }

    @Published private(set) var playlists: [LibraryPlaylist]?
    @Published private(set) var likedIDs: [String]?
    @Published private(set) var likedSet: Set<String> = []
    @Published private(set) var recents: [LibraryContext] = []
    @Published private(set) var playlistState: State = .loading
    @Published private(set) var likesState: State = .loading
    @Published private(set) var mutationBusy = false
    @Published private(set) var actionError: String?
    private let api: any LibraryCollectionsFetching
    private let database: LibraryDatabase
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private var observation: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshNeeded = false
    private var recentWrite: Task<Void, Never>?
    private var session: DeviceSession?
    private var generation = 0

    init(api: any LibraryCollectionsFetching = LibraryCollectionsAPI(), database: LibraryDatabase,
         sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>) {
        self.api = api
        self.database = database
        self.sessionUpdates = sessionUpdates
    }

    deinit {
        observation?.cancel()
        refreshTask?.cancel()
    }

    func start() {
        guard observation == nil else { return }
        let updates = sessionUpdates
        observation = Task { [weak self] in
            do {
                for await session in try await updates() {
                    guard !Task.isCancelled else { return }
                    await self?.changeSession(session)
                }
            } catch {
                self?.playlistState = .unavailable
                self?.likesState = .unavailable
            }
        }
    }

    func clearError() { actionError = nil }

    func playlist(named name: String) -> LibraryPlaylist? {
        playlists?.first { $0.name == name && $0.liked != true }
    }

    func record(_ context: LibraryContext) {
        guard let session else { return }
        recents = Array(([context] + recents.filter { $0 != context }).prefix(12))
        let recentContexts = recents
        let prior = recentWrite
        recentWrite = Task {
            await prior?.value
            await save(recentContexts, key: "recents", session: session)
        }
    }

    func refresh(for expectedSession: DeviceSession? = nil) async {
        guard let session, expectedSession == nil || expectedSession == session else { return }
        if mutationBusy || refreshTask != nil {
            refreshNeeded = true
            return
        }
        let request = generation
        let task = Task {
            repeat {
                refreshNeeded = false
                async let remotePlaylists = try? api.playlists(for: session)
                async let remoteLikes = try? api.likes(for: session)
                let (newPlaylists, newLikes) = await (remotePlaylists, remoteLikes)
                guard request == generation, !Task.isCancelled else { return }
                if let newPlaylists {
                    playlists = newPlaylists
                    playlistState = .ready
                    await save(newPlaylists, key: "playlists", session: session)
                } else {
                    playlistState = .unavailable
                }
                guard request == generation, !Task.isCancelled else { return }
                if let newLikes {
                    applyLikes(newLikes)
                    likesState = .ready
                    await save(newLikes, key: "likes", session: session)
                } else {
                    likesState = .unavailable
                }
                guard request == generation, !Task.isCancelled else { return }
            } while refreshNeeded && !mutationBusy
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    func toggleLike(_ track: LibraryTrack) async {
        guard likedIDs != nil else { return }
        let liked = !likedSet.contains(track.id)
        await mutate(failure: "Could not update this song’s like. Try again.") { session in
            try await api.setLiked(liked, trackID: track.id, session: session)
        } apply: {
            let remaining = (likedIDs ?? []).filter { $0 != track.id }
            applyLikes(liked ? [track.id] + remaining : remaining)
        }
    }

    func toggleFavorite(_ name: String) async {
        guard let old = playlist(named: name)?.favorite else { return }
        await mutate(failure: "Could not update this playlist’s favorite. Try again.") { session in
            try await api.setFavorite(!old, name: name, session: session)
        } apply: {
            guard let index = playlists?.firstIndex(where: { $0.name == name }) else { return }
            playlists?[index].favorite = !old
        }
    }

    private func mutate(failure: String, write: (DeviceSession) async throws -> Void, apply: () -> Void) async {
        guard let session, !mutationBusy else { return }
        let request = generation
        mutationBusy = true
        await refreshTask?.value
        guard request == generation else { return }
        do {
            try await write(session)
            guard request == generation else { return }
            apply()
            if let playlists { await save(playlists, key: "playlists", session: session) }
            guard request == generation else { return }
            if let likedIDs { await save(likedIDs, key: "likes", session: session) }
        } catch {
            guard request == generation else { return }
            actionError = failure
        }
        guard request == generation else { return }
        mutationBusy = false
        await refresh(for: session)
    }

    private func changeSession(_ newSession: DeviceSession?) async {
        guard session != newSession else { return }
        generation += 1
        let request = generation
        session = newSession
        refreshTask?.cancel()
        refreshTask = nil
        refreshNeeded = false
        playlists = nil
        applyLikes(nil)
        recents = []
        playlistState = .loading
        likesState = .loading
        mutationBusy = false
        actionError = nil
        guard let newSession else { return }

        // Delay remote refreshes until the initial cache has been read.
        mutationBusy = true
        let cachedPlaylists: [LibraryPlaylist]? = await load("playlists", session: newSession)
        let cachedLikes: [String]? = await load("likes", session: newSession)
        await recentWrite?.value
        let cachedRecents: [LibraryContext]? = await load("recents", session: newSession)
        guard request == generation else { return }
        playlists = cachedPlaylists
        applyLikes(cachedLikes)
        recents = cachedRecents ?? []
        mutationBusy = false
        Task { await refresh(for: newSession) }
    }

    private func applyLikes(_ ids: [String]?) {
        likedIDs = ids
        likedSet = Set(ids ?? [])
    }

    private func load<T: Decodable>(_ key: String, session: DeviceSession) async -> T? {
        guard let data = try? await database.browseData(key, in: scope(session)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String, session: DeviceSession) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? await database.saveBrowseData(data, key: key, in: scope(session))
    }

    private func scope(_ session: DeviceSession) -> LibraryScope {
        LibraryScope(serverID: session.serverID, username: session.username, deviceID: session.deviceID)
    }
}
