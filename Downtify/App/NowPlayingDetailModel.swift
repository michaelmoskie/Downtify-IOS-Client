import Foundation

struct NowPlayingArtistCatalog: Equatable, Sendable {
    let artist: CatalogArtist
    let bio: String
    let songs: [CatalogSong]
    let albums: [CatalogAlbum]
}

struct NowPlayingAlbumCatalog: Equatable, Sendable {
    let album: CatalogAlbum
    let tracks: [CatalogSong]
}

/// Loads catalog content for one artist or album page opened from Now Playing.
/// It owns its requests so the Search tab's shared Finder state is never replaced or cancelled.
@MainActor
final class NowPlayingDetailModel: ObservableObject {
    @Published private(set) var artistState: CatalogLoadState<NowPlayingArtistCatalog> = .idle
    @Published private(set) var albumState: CatalogLoadState<NowPlayingAlbumCatalog> = .idle

    private let api: any CatalogServing
    private var artistRequest: UUID?
    private var albumRequest: UUID?

    init(api: any CatalogServing = CatalogAPI()) {
        self.api = api
    }

    func loadArtist(_ target: NowPlayingArtistTarget, session: DeviceSession?, providerDetailsAvailable: Bool) async {
        let request = UUID()
        artistRequest = request
        guard let session else {
            artistState = .unavailable(message: "Connect to a server to browse this artist.")
            return
        }
        guard providerDetailsAvailable else {
            artistState = .unavailable(message: "Provider artist details are unavailable in library-only mode.")
            return
        }
        artistState = .loading
        let api = self.api
        do {
            var id = target.providerArtistID
            if id == nil {
                let results = try await api.finderSearch(query: target.name, limit: 10, session: session)
                id = CatalogNameMatch.bestArtist(named: target.name, in: results.artists)
                    .flatMap(CatalogNameMatch.providerArtistID)
            }
            guard artistRequest == request else { return }
            guard let id else {
                artistState = .empty
                return
            }
            let name = target.name
            async let details = api.finderArtist(id: id, language: "en", session: session)
            async let songs = Self.attempt { try await api.finderArtistSongs(id: id, name: name, session: session).tracks }
            async let albums = Self.attempt { try await api.finderArtistAlbums(id: id, session: session) }
            let artist = try await details
            let (songResult, albumResult) = await (songs, albums)
            guard artistRequest == request, !Task.isCancelled else { return }
            let loadedSongs = (try? songResult.get()).flatMap { $0.isEmpty ? nil : $0 } ?? artist.topSongs
            let value = NowPlayingArtistCatalog(artist: artist.artist, bio: artist.bio, songs: loadedSongs,
                                                albums: (try? albumResult.get()) ?? [])
            if case .failure(let error) = albumResult, !(error is CancellationError) {
                artistState = .partial(value, message: "Some catalog sections could not be loaded.")
            } else {
                artistState = .loaded(value)
            }
        } catch is CancellationError {
            return
        } catch {
            guard artistRequest == request else { return }
            artistState = Self.state(for: error)
        }
    }

    func loadAlbum(_ target: NowPlayingAlbumTarget, session: DeviceSession?, providerDetailsAvailable: Bool) async {
        let request = UUID()
        albumRequest = request
        guard let session else {
            albumState = .unavailable(message: "Connect to a server to browse this album.")
            return
        }
        guard providerDetailsAvailable else {
            albumState = .unavailable(message: "Provider album details are unavailable in library-only mode.")
            return
        }
        albumState = .loading
        do {
            var id = target.providerAlbumID
            if id == nil {
                let query = [target.artist, target.title].filter { !$0.isEmpty }.joined(separator: " ")
                let results = try await api.finderSearch(query: query, limit: 10, session: session)
                id = CatalogNameMatch.bestAlbum(title: target.title, artist: target.artist, in: results.albums)
                    .flatMap(CatalogNameMatch.providerAlbumID)
            }
            guard albumRequest == request else { return }
            guard let id else {
                albumState = .empty
                return
            }
            let album = try await api.finderAlbum(id: id, session: session)
            guard albumRequest == request, !Task.isCancelled else { return }
            albumState = album.tracks.isEmpty ? .empty : .loaded(NowPlayingAlbumCatalog(album: album.album, tracks: album.tracks))
        } catch is CancellationError {
            return
        } catch {
            guard albumRequest == request else { return }
            albumState = Self.state(for: error)
        }
    }

    private static func attempt<Value: Sendable>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private static func state<Value: Equatable & Sendable>(for error: Error) -> CatalogLoadState<Value> {
        let message = CatalogPresentationModel.message(for: error)
        return CatalogPresentationModel.isUnavailable(error) ? .unavailable(message: message) : .failed(message: message)
    }
}
