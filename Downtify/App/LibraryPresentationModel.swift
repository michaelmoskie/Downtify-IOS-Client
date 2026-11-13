import Combine
import Foundation
import Network
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
    @Published private(set) var pendingActions: [PendingCollectionAction] = []
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
    private let verifySession: (DeviceSession) async -> Bool
    private var actionTask: Task<Void, Never>?
    private var enqueueTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private var pathAvailable = false
    private var appActive = false

    init(api: any LibraryCollectionsFetching = LibraryCollectionsAPI(preservesTransportErrors: true), database: LibraryDatabase,
         sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>,
         verifySession: @escaping (DeviceSession) async -> Bool = { _ in false }) {
        self.api = api
        self.database = database
        self.sessionUpdates = sessionUpdates
        self.verifySession = verifySession
    }

    deinit {
        observation?.cancel()
        refreshTask?.cancel()
        actionTask?.cancel()
        enqueueTask?.cancel()
        networkMonitor?.cancel()
    }

    func start() {
        guard observation == nil else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.setActionsPathAvailable(path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.downtify.collection-actions"))
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

    func effectiveLike(_ trackID: String) -> Bool {
        for action in pendingActions.reversed() where action.status == .queued {
            if case .like(let id) = action.target, id == trackID { return action.desiredValue }
        }
        return likedSet.contains(trackID)
    }

    func effectiveFavorite(_ playlist: LibraryPlaylist) -> Bool {
        for action in pendingActions.reversed() where action.status == .queued {
            if case .favorite(let name, _, _) = action.target, name == playlist.name { return action.desiredValue }
        }
        return playlist.favorite ?? false
    }

    func hasPendingLike(_ trackID: String) -> Bool {
        pendingActions.contains { action in
            guard action.status == .queued, case .like(let id) = action.target else { return false }
            return id == trackID
        }
    }

    func hasPendingFavorite(_ name: String) -> Bool {
        pendingActions.contains { action in
            guard action.status == .queued, case .favorite(let target, _, _) = action.target else { return false }
            return target == name
        }
    }

    func toggleLike(_ track: LibraryTrack) async {
        guard likedIDs != nil else { return }
        await enqueue { [weak self] in
            guard let self else { return nil }
            return PendingCollectionAction(target: .like(trackID: track.id), desiredValue: !self.effectiveLike(track.id))
        }
    }

    func toggleFavorite(_ name: String) async {
        await enqueue { [weak self] in
            guard let self, let playlist = self.playlist(named: name), playlist.favorite != nil else { return nil }
            return PendingCollectionAction(target: .favorite(name: playlist.name, owner: playlist.owner, manual: playlist.manual),
                                           desiredValue: !self.effectiveFavorite(playlist))
        }
    }

    private func enqueue(_ make: @escaping @MainActor () -> PendingCollectionAction?) async {
        guard let session else { return }
        let request = generation
        let prior = enqueueTask
        let task = Task { [weak self] in
            await prior?.value
            guard let self, !Task.isCancelled, self.generation == request, let action = make() else { return }
            do {
                try await self.database.appendPendingAction(action, in: self.scope(session), deviceID: session.deviceID)
                guard self.generation == request, !Task.isCancelled else { return }
                self.pendingActions.append(action)
                self.startActionDrain()
            } catch {
                guard self.generation == request else { return }
                self.actionError = "Could not save this action. Please try again."
            }
        }
        enqueueTask = task
        await task.value
    }

    func dismissAction(_ id: UUID) async {
        guard let session, let action = pendingActions.first(where: { $0.id == id }), action.status != .queued else { return }
        let request = generation
        do {
            try await database.removePendingAction(id, in: scope(session), deviceID: session.deviceID)
            guard request == generation else { return }
            pendingActions.removeAll { $0.id == id }
        } catch { actionError = "Could not remove this action. Please try again." }
    }

    func setActionsPathAvailable(_ available: Bool) {
        pathAvailable = available
        if available { startActionDrain() }
        else { actionTask?.cancel() }
    }

    func setActionsActive(_ active: Bool) {
        appActive = active
        if active { startActionDrain() }
        else { actionTask?.cancel() }
    }

    private func startActionDrain() {
        guard actionTask == nil, appActive, pathAvailable, session != nil else { return }
        let request = generation
        actionTask = Task { [weak self] in await self?.drainActions(generation: request) }
    }

    private func drainActions(generation request: Int) async {
        defer {
            if request == generation {
                actionTask = nil
                if Task.isCancelled && appActive && pathAvailable { startActionDrain() }
            }
        }
        while request == generation, appActive, pathAvailable, !Task.isCancelled,
              let session, let index = pendingActions.firstIndex(where: { $0.status == .queued }) {
            var action = pendingActions[index]
            if let next = action.nextAttempt, next > Date() {
                do { try await Task.sleep(for: .seconds(next.timeIntervalSinceNow)) }
                catch { return }
                continue
            }
            do {
                if case .favorite(let name, let owner, let manual) = action.target {
                    let current = try await api.playlists(for: session)
                    try Task.checkCancellation()
                    guard let match = current.first(where: { $0.name == name && $0.liked != true }),
                          (owner == nil || owner == match.owner), (manual == nil || manual == match.manual) else {
                        throw PendingActionFailure.targetChanged
                    }
                }
                try Task.checkCancellation()
                switch action.target {
                case .like(let id): try await api.setLiked(action.desiredValue, trackID: id, session: session)
                case .favorite(let name, _, _): try await api.setFavorite(action.desiredValue, name: name, session: session)
                }
                guard request == generation, !Task.isCancelled else { return }
                action.status = .sent
                action.nextAttempt = nil
                do {
                    try await database.updatePendingAction(action, in: scope(session), deviceID: session.deviceID)
                } catch {
                    guard request == generation else { return }
                    actionError = "Could not save the action’s status. Delivery has stopped."
                    return
                }
                guard request == generation, !Task.isCancelled else { return }
                replacePendingAction(action)
                // An acknowledged value is confirmed until the authoritative refresh completes.
                switch action.target {
                case .like(let id):
                    let remaining = (likedIDs ?? []).filter { $0 != id }
                    applyLikes(action.desiredValue ? [id] + remaining : remaining)
                case .favorite(let name, _, _):
                    if let index = playlists?.firstIndex(where: { $0.name == name }) {
                        playlists?[index].favorite = action.desiredValue
                    }
                }
                await refresh(for: session)
            } catch is CancellationError { return }
            catch {
                guard request == generation, !Task.isCancelled else { return }
                if case APIError.httpStatus(401, _) = error {
                    guard await verifySession(session), request == generation, !Task.isCancelled else { return }
                }
                action.attempts += 1
                if let delay = Self.retryDelay(for: error, attempt: action.attempts), action.attempts < 5 {
                    action.nextAttempt = Date().addingTimeInterval(delay)
                } else {
                    action.status = .failed
                    action.failure = failureMessage(for: error)
                    action.nextAttempt = nil
                }
                do {
                    try await database.updatePendingAction(action, in: scope(session), deviceID: session.deviceID)
                    guard request == generation, !Task.isCancelled else { return }
                    replacePendingAction(action)
                } catch {
                    actionError = "Could not save the action’s status. Delivery has stopped."
                    return
                }
            }
        }
    }

    private enum PendingActionFailure: Error { case targetChanged }

    static func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        let base = pow(2.0, Double(attempt))
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .dnsLookupFailed, .cannotConnectToHost: return base
            default: return nil
            }
        }
        if case APIError.httpStatus(let status, let retryAfter) = error,
           [401, 408, 429, 502, 503, 504].contains(status) {
            return max(base, retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0)
        }
        return nil
    }

    private func failureMessage(for error: Error) -> String {
        if error is PendingActionFailure { return "The playlist changed or is no longer available. Choose it again." }
        if case APIError.httpStatus(let status, _) = error { return "Server returned HTTP \(status)." }
        return "The action could not be sent. Choose the item and try again."
    }

    private func replacePendingAction(_ action: PendingCollectionAction) {
        if let index = pendingActions.firstIndex(where: { $0.id == action.id }) { pendingActions[index] = action }
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

    private func changeSession(_ newSession: DeviceSession?) async {
        guard session != newSession else { return }
        let previous = session
        generation += 1
        let request = generation
        actionTask?.cancel()
        actionTask = nil
        enqueueTask?.cancel()
        await enqueueTask?.value
        enqueueTask = nil
        if let previous {
            do { try await database.removePendingActions(in: scope(previous), deviceID: previous.deviceID) }
            catch { actionError = "Could not clear pending actions for the previous session." }
        }
        guard request == generation else { return }
        pendingActions = []
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
        do {
            pendingActions = try await database.pendingActions(in: scope(newSession), deviceID: newSession.deviceID)
        } catch {
            actionError = "Could not load pending actions. Delivery has stopped."
            return
        }
        guard request == generation else { return }
        startActionDrain()

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
