import Combine
import Foundation

/// State for one independently loaded catalog section. Discover surfaces can
/// therefore keep successful sections visible when another provider fails.
enum CatalogLoadState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case empty
    case loaded(Value)
    case partial(Value, message: String)
    case unavailable(message: String)
    case failed(message: String)
}

enum CatalogPolicyState: Equatable, Sendable {
    case unknown
    case loading
    case ready
    case failed(String)
}

@MainActor
final class CatalogPresentationModel: ObservableObject {
    @Published private(set) var session: DeviceSession?
    @Published private(set) var serverInfo: MobileAPIV1.ServerInfoDTO?
    @Published private(set) var policyState: CatalogPolicyState = .unknown
    @Published private(set) var policyGeneration = 0

    @Published private(set) var searchQuery = ""
    @Published private(set) var searchSongsState: CatalogLoadState<[CatalogSong]> = .idle
    @Published private(set) var searchAlbumsState: CatalogLoadState<[CatalogAlbum]> = .idle
    @Published private(set) var searchArtistsState: CatalogLoadState<[CatalogArtist]> = .idle

    @Published private(set) var urlResolutionState: CatalogLoadState<URLResolution> = .idle
    @Published private(set) var finderSearchState: CatalogLoadState<CatalogSearchResults> = .idle
    @Published private(set) var finderArtistState: CatalogLoadState<CatalogFinderArtist> = .idle
    @Published private(set) var finderAlbumState: CatalogLoadState<CatalogFinderAlbum> = .idle
    @Published private(set) var chartsState: CatalogLoadState<CatalogCharts> = .idle
    @Published private(set) var similarState: CatalogLoadState<CatalogSimilarResults> = .idle
    @Published private(set) var discoverArtistsState: CatalogLoadState<CatalogDiscoverResults> = .idle
    @Published private(set) var deezerCollectionsState: CatalogLoadState<CatalogCollectionsResults> = .idle
    @Published private(set) var spotifyCollectionsState: CatalogLoadState<CatalogCollectionsResults> = .idle
    @Published private(set) var blockedArtistsState: CatalogLoadState<[CatalogBlockedArtist]> = .idle
    @Published private(set) var mutationState: CatalogLoadState<CatalogBlockedArtist> = .idle

    var isLibraryOnly: Bool? { serverInfo.map(\.isLibraryOnly) }
    var supportsDiscover: Bool? { serverInfo.map(\.supportsDiscover) }
    var externalCatalogAvailable: Bool { serverInfo.map { !$0.isLibraryOnly } ?? false }
    var providerFinderDetailsAvailable: Bool { externalCatalogAvailable && supportsDiscover == true }

    private let api: any CatalogServing
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private var observation: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    private var requests: [String: Task<Void, Never>] = [:]
    private var requestIDs: [String: UUID] = [:]

    init(
        api: any CatalogServing = CatalogAPI(),
        sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>
    ) {
        self.api = api
        self.sessionUpdates = sessionUpdates
    }

    deinit {
        observation?.cancel()
        policyTask?.cancel()
        requests.values.forEach { $0.cancel() }
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                for await session in try await sessionUpdates() {
                    guard !Task.isCancelled else { return }
                    setSession(session)
                }
            } catch {
                policyState = .failed("Could not check server capabilities.")
            }
        }
    }

    /// Also called on `music_policy_changed` and WebSocket reconnect events.
    func refreshPolicy(for expectedSession: DeviceSession) async {
        guard session == expectedSession else { return }
        policyTask?.cancel()
        let requestID = UUID()
        requestIDs["policy"] = requestID
        policyState = .loading
        do {
            let info = try await api.serverInfo(session: expectedSession)
            guard isCurrent("policy", id: requestID, session: expectedSession) else { return }
            let policyChanged = serverInfo != nil && (
                serverInfo?.isLibraryOnly != info.isLibraryOnly || serverInfo?.supportsDiscover != info.supportsDiscover
            )
            serverInfo = info
            policyState = .ready
            if policyChanged {
                invalidateRequests()
                clearCatalogSections()
                policyGeneration += 1
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent("policy", id: requestID, session: expectedSession) else { return }
            policyState = .failed(message(for: error))
        }
    }

    func search(_ query: String, albumLimit: Int = 25) {
        searchQuery = query
        cancelRequests(withPrefix: "search_")
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            searchSongsState = .idle
            searchAlbumsState = .idle
            searchArtistsState = .idle
            return
        }
        guard let session else {
            searchSongsState = .unavailable(message: "Connect to a server to search its catalog.")
            searchAlbumsState = .unavailable(message: "Connect to a server to search its catalog.")
            searchArtistsState = .unavailable(message: "Connect to a server to search its catalog.")
            return
        }
        let api = self.api
        startRequest("search_songs", session: session, operation: { try await api.searchSongs(query: normalized, session: session) },
                     isEmpty: \.isEmpty) { self.searchSongsState = $0 }
        startRequest("search_albums", session: session, operation: { try await api.searchAlbums(query: normalized, limit: albumLimit, session: session) },
                     isEmpty: \.isEmpty) { self.searchAlbumsState = $0 }
        startRequest("search_artists", session: session, operation: { try await api.searchArtists(query: normalized, session: session) },
                     isEmpty: \.isEmpty) { self.searchArtistsState = $0 }
    }

    func resolveURL(_ url: String) {
        guard let session else {
            urlResolutionState = .unavailable(message: "Connect to a server to resolve a link.")
            return
        }
        guard externalCatalogAvailable else {
            urlResolutionState = .unavailable(message: "Link resolution is unavailable in library-only mode.")
            return
        }
        let api = self.api
        startRequest("resolve", session: session, operation: { try await api.resolve(url: url, session: session) },
                     isEmpty: { $0.tracks.isEmpty && $0.albums.isEmpty }) { self.urlResolutionState = $0 }
    }

    func searchFinder(_ query: String, limit: Int = 25) {
        guard let session else {
            finderSearchState = .unavailable(message: "Connect to a server to search Finder.")
            return
        }
        let api = self.api
        startRequest("finder_search", session: session, operation: { try await api.finderSearch(query: query, limit: limit, session: session) },
                     isEmpty: { $0.tracks.isEmpty && $0.albums.isEmpty && $0.artists.isEmpty }) {
            self.finderSearchState = $0
        }
    }

    func loadFinderArtist(id: String, language: String = "en") {
        guard let session else {
            finderArtistState = .unavailable(message: "Connect to a server to browse this artist.")
            return
        }
        guard providerFinderDetailsAvailable else {
            finderArtistState = .unavailable(message: "Provider artist details are unavailable in library-only mode.")
            return
        }
        let api = self.api
        startRequest("finder_artist", session: session, operation: { try await api.finderArtist(id: id, language: language, session: session) },
                     isEmpty: { $0.artist.name.isEmpty }) { self.finderArtistState = $0 }
    }

    func loadFinderAlbum(id: String) {
        guard let session else {
            finderAlbumState = .unavailable(message: "Connect to a server to browse this album.")
            return
        }
        guard providerFinderDetailsAvailable else {
            finderAlbumState = .unavailable(message: "Provider album details are unavailable in library-only mode.")
            return
        }
        let api = self.api
        startRequest("finder_album", session: session, operation: { try await api.finderAlbum(id: id, session: session) },
                     isEmpty: { $0.tracks.isEmpty }) { self.finderAlbumState = $0 }
    }

    func loadCharts(limit: Int = 25) {
        guard let session else {
            chartsState = .unavailable(message: "Connect to a server to load charts.")
            return
        }
        let api = self.api
        startRequest("charts", session: session, operation: { try await api.charts(limit: limit, session: session) },
                     isEmpty: { $0.tracks.isEmpty && $0.albums.isEmpty && $0.artists.isEmpty && $0.playlists.isEmpty }) {
            self.chartsState = $0
        }
    }

    func loadSimilar(artist: String = "", track: String = "", limit: Int = 20) {
        guard let session else {
            similarState = .unavailable(message: "Connect to a server to load similar tracks.")
            return
        }
        let api = self.api
        startRequest("similar", session: session, operation: { try await api.similar(artist: artist, track: track, limit: limit, session: session) },
                     isEmpty: { $0.tracks.isEmpty }) { self.similarState = $0 }
    }

    func loadDiscover(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistNames: [String],
                      playlistIDs: [String], shown: [String]) {
        guard let session else {
            discoverArtistsState = .unavailable(message: "Connect to a server to load Discover.")
            deezerCollectionsState = .unavailable(message: "Connect to a server to load Discover.")
            spotifyCollectionsState = .unavailable(message: "Connect to a server to load Discover.")
            return
        }
        guard supportsDiscover == true else {
            let message = "Discover is unavailable on this server."
            discoverArtistsState = .unavailable(message: message)
            deezerCollectionsState = .unavailable(message: message)
            spotifyCollectionsState = .unavailable(message: message)
            return
        }
        let api = self.api
        startRequest("discover_artists", session: session, operation: { try await api.discover(library: library, session: session) },
                     isEmpty: { $0.artists.isEmpty }, isPartial: { $0.partial }) { self.discoverArtistsState = $0 }
        startRequest("deezer_collections", session: session, operation: {
            try await api.deezerCollections(library: library, albums: albums, playlistNames: playlistNames, session: session)
        }, isEmpty: { $0.albums.isEmpty && $0.moreAlbums.isEmpty && $0.playlists.isEmpty }, isPartial: { $0.partial }) {
            self.deezerCollectionsState = $0
        }
        startRequest("spotify_collections", session: session, operation: {
            try await api.spotifyCollections(library: library, albums: albums, playlistIDs: playlistIDs, shown: shown, session: session)
        }, isEmpty: { $0.albums.isEmpty && $0.moreAlbums.isEmpty && $0.playlists.isEmpty }, isPartial: { $0.partial }) {
            self.spotifyCollectionsState = $0
        }
    }

    func loadBlockedArtists() {
        guard let session else {
            blockedArtistsState = .unavailable(message: "Connect to a server to load blocked artists.")
            return
        }
        let api = self.api
        startRequest("blocked", session: session, operation: { try await api.blockedArtists(session: session) },
                     isEmpty: \.isEmpty) { self.blockedArtistsState = $0 }
    }

    func blockArtist(_ name: String) {
        mutateBlock(name: name) { api, session in try await api.blockArtist(name: name, session: session) }
    }

    func unblockArtist(_ name: String) {
        guard let session else { return }
        let api = self.api
        let requestID = UUID()
        requestIDs["block_mutation"] = requestID
        mutationState = .loading
        requests["block_mutation"]?.cancel()
        requests["block_mutation"] = Task { [weak self] in
            do {
                try await api.unblockArtist(name: name, session: session)
                guard let self, self.isCurrent("block_mutation", id: requestID, session: session) else { return }
                self.mutationState = .empty
                self.loadBlockedArtists()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent("block_mutation", id: requestID, session: session) else { return }
                self.mutationState = .failed(message: self.message(for: error))
            }
        }
    }

    private func mutateBlock(name: String, operation: @escaping (any CatalogServing, DeviceSession) async throws -> CatalogBlockedArtist) {
        guard let session else { return }
        let api = self.api
        let requestID = UUID()
        requestIDs["block_mutation"] = requestID
        mutationState = .loading
        requests["block_mutation"]?.cancel()
        requests["block_mutation"] = Task { [weak self] in
            do {
                let result = try await operation(api, session)
                guard let self, self.isCurrent("block_mutation", id: requestID, session: session) else { return }
                self.mutationState = .loaded(result)
                self.loadBlockedArtists()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent("block_mutation", id: requestID, session: session) else { return }
                self.mutationState = .failed(message: self.message(for: error))
            }
        }
    }

    private func setSession(_ newSession: DeviceSession?) {
        guard session != newSession else { return }
        invalidateRequests()
        session = newSession
        serverInfo = nil
        policyState = newSession == nil ? .unknown : .loading
        policyGeneration += 1
        searchQuery = ""
        clearCatalogSections()
        guard let newSession else { return }
        let api = self.api
        let requestID = UUID()
        requestIDs["policy"] = requestID
        policyTask = Task { [weak self] in
            do {
                let info = try await api.serverInfo(session: newSession)
                guard let self, self.isCurrent("policy", id: requestID, session: newSession) else { return }
                self.serverInfo = info
                self.policyState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent("policy", id: requestID, session: newSession) else { return }
                self.policyState = .failed(message(for: error))
            }
        }
    }

    private func startRequest<Value: Equatable & Sendable>(
        _ key: String, session: DeviceSession, operation: @escaping () async throws -> Value,
        isEmpty: @escaping (Value) -> Bool, isPartial: @escaping (Value) -> Bool = { _ in false },
        setState: @escaping (CatalogLoadState<Value>) -> Void
    ) {
        requests[key]?.cancel()
        let requestID = UUID()
        requestIDs[key] = requestID
        setState(.loading)
        requests[key] = Task { [weak self] in
            do {
                let value = try await operation()
                guard let self, self.isCurrent(key, id: requestID, session: session) else { return }
                if isPartial(value) { setState(.partial(value, message: "Some catalog sections could not be loaded.")) }
                else if isEmpty(value) { setState(.empty) }
                else { setState(.loaded(value)) }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent(key, id: requestID, session: session) else { return }
                setState(self.isUnavailable(error)
                         ? .unavailable(message: self.message(for: error))
                         : .failed(message: self.message(for: error)))
            }
        }
    }

    private func isCurrent(_ key: String, id: UUID, session: DeviceSession) -> Bool {
        self.session == session && requestIDs[key] == id
    }

    private func invalidateRequests() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        requestIDs.removeAll()
        policyTask?.cancel()
    }

    private func cancelRequests(withPrefix prefix: String) {
        let keys = requests.keys.filter { $0.hasPrefix(prefix) }
        for key in keys {
            requests[key]?.cancel()
            requests[key] = nil
            requestIDs[key] = nil
        }
    }

    private func clearCatalogSections() {
        searchSongsState = .idle
        searchAlbumsState = .idle
        searchArtistsState = .idle
        urlResolutionState = .idle
        finderSearchState = .idle
        finderArtistState = .idle
        finderAlbumState = .idle
        chartsState = .idle
        similarState = .idle
        discoverArtistsState = .idle
        deezerCollectionsState = .idle
        spotifyCollectionsState = .idle
        blockedArtistsState = .idle
        mutationState = .idle
    }

    private func isUnavailable(_ error: Error) -> Bool {
        if let error = error as? CatalogAPIError {
            return error == .featureUnavailable || error == .libraryOnly
        }
        return false
    }

    private func message(for error: Error) -> String {
        if let error = error as? CatalogAPIError {
            switch error {
            case .invalidInput: "This request is not valid."
            case .libraryOnly: "External catalog actions are unavailable in library-only mode."
            case .featureUnavailable: "This feature is unavailable on this server."
            }
        } else if case APIError.httpStatus(let status, _) = error {
            "The server could not complete this request (\(status))."
        } else if error is CancellationError {
            "Request cancelled."
        } else {
            "Could not load catalog results."
        }
    }
}
