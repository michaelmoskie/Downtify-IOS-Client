import Combine
import Foundation
import SwiftUI

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
    private var manualRefreshTask: Task<Void, Never>?

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
        if let manualRefreshTask {
            await manualRefreshTask.value
            return
        }
        let task = Task { await performManualRefresh() }
        manualRefreshTask = task
        await task.value
        manualRefreshTask = nil
    }

    private func performManualRefresh() async {
        guard let session else { return }
        let request = generation
        state = tracks.isEmpty ? .loading : .refreshing
        do {
            _ = try await NetworkOperationContext.$priority.withValue(.userFacing) {
                try await repository.sync(for: session, refresh: true)
            }
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

    enum PlaylistMutationOperation: Equatable {
        case creating, renaming, addingTracks, removingTracks, removingTrack, reordering
    }

    enum PlaylistMutationError: Equatable {
        case conflictRequiresReview
        case conflictRefreshFailed
        case acceptedResponseUnreadable
        case invalidRequest
        case permissionDenied
        case notFound
        case libraryIndexUnavailable
        case httpStatus(Int)
        case unexpected

        static func fromHTTPStatus(_ status: Int) -> Self {
            switch status {
            case 400: .invalidRequest
            case 403: .permissionDenied
            case 404: .notFound
            case 503: .libraryIndexUnavailable
            default: .httpStatus(status)
            }
        }
    }

    @Published private(set) var playlists: [LibraryPlaylist]?
    @Published private(set) var supportsPlaylistEditing = false
    @Published private(set) var likedIDs: [String]?
    @Published private(set) var likedSet: Set<String> = []
    @Published private(set) var recents: [LibraryContext] = []
    @Published private(set) var playlistState: State = .loading
    @Published private(set) var likesState: State = .loading
    @Published private(set) var mutationBusy = false
    @Published private(set) var actionError: LocalizedStringKey?
    @Published private(set) var activePlaylistMutation: PlaylistMutationOperation?
    @Published private(set) var playlistMutationError: PlaylistMutationError?
    private let api: any LibraryCollectionsFetching
    private let database: LibraryDatabase
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private var observation: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshNeeded = false
    private var recentWrite: Task<Void, Never>?
    private var session: DeviceSession?
    private var generation = 0
    private var playlistNameAliases: [String: String] = [:]

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

    func clearPlaylistMutationError() { playlistMutationError = nil }

    func playlist(named name: String) -> LibraryPlaylist? {
        let resolvedName = resolvedPlaylistName(name)
        return playlists?.first { $0.name == resolvedName && $0.liked != true }
    }

    func record(_ context: LibraryContext) {
        guard let session else { return }
        let context = canonicalContext(context)
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

    func createPlaylist(name: String) async {
        _ = await mutatePlaylist(.creating) { session in
            try await api.createPlaylist(name: name, session: session)
        }
    }

    func renamePlaylist(name: String, to newName: String) async {
        let currentName = playlist(named: name)?.name ?? name
        _ = await mutatePlaylist(.renaming) { session in
            try await api.renamePlaylist(name: currentName, to: newName, session: session)
        }
    }

    func addTracks(_ trackIDs: [String], to name: String, allowDuplicates: Bool = false) async {
        guard !trackIDs.isEmpty else { return }
        _ = await mutatePlaylist(.addingTracks) { session in
            try await api.editPlaylistTracks(
                name: name, add: trackIDs, remove: nil, removeEntries: nil,
                allowDuplicates: allowDuplicates, session: session
            )
        }
    }

    /// Removes every occurrence of each supplied track ID.
    func removeTracks(_ trackIDs: [String], from name: String) async {
        guard !trackIDs.isEmpty else { return }
        _ = await mutatePlaylist(.removingTracks) { session in
            try await api.editPlaylistTracks(
                name: name, add: nil, remove: trackIDs, removeEntries: nil,
                allowDuplicates: nil, session: session
            )
        }
    }

    /// `occurrence` is the zero-based rank among copies of `trackID`, not the playlist row position.
    func removePlaylistOccurrence(trackID: String, occurrence: Int, from name: String) async {
        guard occurrence >= 0 else {
            playlistMutationError = .invalidRequest
            return
        }
        let entry = PlaylistTrackEditsRequestDTO.RemovalEntry(trackID: trackID, occurrence: occurrence)
        _ = await mutatePlaylist(.removingTrack) { session in
            try await api.editPlaylistTracks(
                name: name, add: nil, remove: nil, removeEntries: [entry],
                allowDuplicates: nil, session: session
            )
        }
    }

    func reorderPlaylist(_ name: String, trackIDs: [String]) async {
        guard let playlist = playlist(named: name),
              PlaylistTrackOccurrence.completeOrder(
                PlaylistTrackOccurrence.ordered(trackIDs), matching: playlist.trackIDs
              ) != nil else {
            playlistMutationError = .invalidRequest
            return
        }
        _ = await mutatePlaylist(.reordering) { session in
            try await api.reorderPlaylist(name: name, trackIDs: trackIDs, session: session)
        }
    }

    private func mutatePlaylist(
        _ operation: PlaylistMutationOperation,
        write: (DeviceSession) async throws -> PlaylistMutationResponseDTO
    ) async -> PlaylistMutationResponseDTO? {
        guard let session, !mutationBusy else { return nil }
        let request = generation
        mutationBusy = true
        activePlaylistMutation = operation
        playlistMutationError = nil
        actionError = nil
        await refreshTask?.value
        guard request == generation else { return nil }
        var response: PlaylistMutationResponseDTO?
        do {
            response = try await write(session)
            if let response, request == generation {
                applyPlaylistResponse(response)
                if operation == .renaming, let previous = response.previous {
                    applyPlaylistRename(from: previous, to: response.name, session: session)
                }
            }
        } catch {
            guard request == generation else { return nil }
            if case APIError.httpStatus(let status, _) = error {
                // A stale order must be reviewed against the refreshed authoritative list.
                // Never resubmit the original sequence automatically.
                playlistMutationError = status == 409 && operation == .reordering
                    ? .conflictRequiresReview : PlaylistMutationError.fromHTTPStatus(status)
            } else if error is PlaylistWriteError {
                playlistMutationError = .acceptedResponseUnreadable
            } else {
                playlistMutationError = .unexpected
            }
        }
        guard request == generation else { return nil }
        mutationBusy = false
        activePlaylistMutation = nil
        await refresh(for: session)
        if playlistMutationError == .conflictRequiresReview && playlistState != .ready {
            playlistMutationError = .conflictRefreshFailed
        }
        return response
    }

    private func applyPlaylistRename(from previous: String, to canonicalName: String, session: DeviceSession) {
        let aliases = playlistNameAliases.keys.filter { playlistNameAliases[$0] == previous }
        for alias in aliases { playlistNameAliases[alias] = canonicalName }
        playlistNameAliases[previous] = canonicalName
        recents = recents.map { context in
            guard case .playlist(let recentName) = context, recentName == previous else { return context }
            return .playlist(canonicalName)
        }
        let recentContexts = recents
        let prior = recentWrite
        let write = Task {
            await prior?.value
            await save(recentContexts, key: "recents", session: session)
        }
        recentWrite = write
    }

    private func applyPlaylistResponse(_ response: PlaylistMutationResponseDTO) {
        let oldName = response.previous ?? response.name
        guard let index = playlists?.firstIndex(where: { $0.name == oldName || $0.name == response.name }),
              let old = playlists?[index] else { return }
        playlists?[index] = LibraryPlaylist(
            name: response.name, displayName: oldName == response.name ? old.displayName : nil,
            liked: old.liked, favorite: old.favorite, trackIDs: response.trackIDs, cover: old.cover,
            owner: old.owner, mine: old.mine, manual: response.manual, canEditTracks: old.canEditTracks,
            visibility: old.visibility, sharedWithMe: old.sharedWithMe, sharedWith: old.sharedWith, editors: old.editors
        )
    }

    func refreshPlaylistAfterConflict() async {
        let wasConflict = playlistMutationError == .conflictRefreshFailed
        await refresh()
        if playlistState == .ready { playlistMutationError = wasConflict ? .conflictRequiresReview : nil }
    }

    private func mutate(failure: LocalizedStringKey, write: (DeviceSession) async throws -> Void, apply: () -> Void) async {
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
        playlistNameAliases.removeAll()
        playlists = nil
        applyLikes(nil)
        recents = []
        playlistState = .loading
        likesState = .loading
        mutationBusy = false
        actionError = nil
        supportsPlaylistEditing = false
        activePlaylistMutation = nil
        playlistMutationError = nil
        guard let newSession else { return }

        Task { await refreshPlaylistEditingCapability(for: newSession, generation: request) }

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

    private func refreshPlaylistEditingCapability(for session: DeviceSession, generation request: Int) async {
        let supported = (try? await api.supportsPlaylistEditing(for: session)) == true
        guard request == generation, self.session == session else { return }
        supportsPlaylistEditing = supported
    }

    private func resolvedPlaylistName(_ name: String) -> String {
        var resolved = name
        var visited = Set<String>()
        while let next = playlistNameAliases[resolved], visited.insert(resolved).inserted {
            resolved = next
        }
        return resolved
    }

    private func canonicalContext(_ context: LibraryContext) -> LibraryContext {
        guard case .playlist(let name) = context else { return context }
        return .playlist(resolvedPlaylistName(name))
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
