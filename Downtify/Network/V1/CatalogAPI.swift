import Foundation

enum CatalogAPIError: Error, Equatable {
    case invalidInput
    case libraryOnly
    case featureUnavailable
}

protocol CatalogServing {
    func serverInfo(session: DeviceSession) async throws -> MobileAPIV1.ServerInfoDTO
    func searchSongs(query: String, session: DeviceSession) async throws -> [CatalogSong]
    func searchAlbums(query: String, limit: Int, session: DeviceSession) async throws -> [CatalogAlbum]
    func searchArtists(query: String, session: DeviceSession) async throws -> [CatalogArtist]
    func search(query: String, albumLimit: Int, session: DeviceSession) async throws -> CatalogSearchResults
    func resolve(url: String, session: DeviceSession) async throws -> URLResolution
    func albumTracks(url: String, session: DeviceSession) async throws -> [CatalogSong]
    func preview(artist: String, title: String, duration: Double?, session: DeviceSession) async throws -> URL?
    func finderSearch(query: String, limit: Int, session: DeviceSession) async throws -> CatalogSearchResults
    func finderArtist(id: String, language: String, session: DeviceSession) async throws -> CatalogFinderArtist
    func finderArtistSongs(id: String, name: String, session: DeviceSession) async throws -> CatalogSearchResults
    func finderArtistAlbums(id: String, session: DeviceSession) async throws -> [CatalogAlbum]
    func finderAlbumTrackCounts(ids: [String], session: DeviceSession) async throws -> [String: Int]
    func finderAlbum(id: String, session: DeviceSession) async throws -> CatalogFinderAlbum
    func charts(limit: Int, session: DeviceSession) async throws -> CatalogCharts
    func similar(artist: String, track: String, limit: Int, session: DeviceSession) async throws -> CatalogSimilarResults
    func discover(library: [CatalogLibraryArtist], session: DeviceSession) async throws -> CatalogDiscoverResults
    func deezerCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistNames: [String], session: DeviceSession) async throws -> CatalogCollectionsResults
    func spotifyCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistIDs: [String], shown: [String], session: DeviceSession) async throws -> CatalogCollectionsResults
    func blockedArtists(session: DeviceSession) async throws -> [CatalogBlockedArtist]
    func blockArtist(name: String, session: DeviceSession) async throws -> CatalogBlockedArtist
    func unblockArtist(name: String, session: DeviceSession) async throws
}

extension CatalogServing {
    func albumTracks(url: String, session: DeviceSession) async throws -> [CatalogSong] {
        try await resolve(url: url, session: session).tracks
    }
}

struct CatalogAPI: CatalogServing {
    private let transport: any HTTPDataLoading

    init(transport: any HTTPDataLoading = ConnectionHTTPTransport()) {
        self.transport = transport
    }

    func serverInfo(session: DeviceSession) async throws -> MobileAPIV1.ServerInfoDTO {
        try Task.checkCancellation()
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let info = try await APIClient(session: transport).serverInfo(at: address)
        try Task.checkCancellation()
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        return info
    }

    func searchSongs(query: String, session: DeviceSession) async throws -> [CatalogSong] {
        try validate(query: query)
        return try await get([CatalogSong].self, path: "/api/songs/search", query: [
            URLQueryItem(name: "query", value: query)
        ], session: session)
    }

    func searchAlbums(query: String, limit: Int = 25, session: DeviceSession) async throws -> [CatalogAlbum] {
        try validate(query: query)
        try validate(limit: limit)
        return try await get([CatalogAlbum].self, path: "/api/albums/search", query: [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: String(limit))
        ], session: session)
    }

    func searchArtists(query: String, session: DeviceSession) async throws -> [CatalogArtist] {
        try validate(query: query)
        return try await get([CatalogArtist].self, path: "/api/artists/search", query: [
            URLQueryItem(name: "query", value: query)
        ], session: session)
    }

    func search(query: String, albumLimit: Int = 25, session: DeviceSession) async throws -> CatalogSearchResults {
        try validate(query: query)
        try validate(limit: albumLimit)
        async let songs = searchSongs(query: query, session: session)
        async let albums = searchAlbums(query: query, limit: albumLimit, session: session)
        async let artists = searchArtists(query: query, session: session)
        return try await CatalogSearchResults(tracks: songs, albums: albums, artists: artists)
    }

    func resolve(url: String, session: DeviceSession) async throws -> URLResolution {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogAPIError.invalidInput }
        return try await get(URLResolution.self, path: "/api/url/resolve", query: [
            URLQueryItem(name: "url", value: url)
        ], session: session, requiresExternalCatalog: true)
    }

    func albumTracks(url: String, session: DeviceSession) async throws -> [CatalogSong] {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogAPIError.invalidInput }
        let data = try await request(path: "/api/song/url", query: [URLQueryItem(name: "url", value: url)],
                                     session: session, requiresExternalCatalog: true, timeoutInterval: 25)
        let decoder = JSONDecoder()
        if let tracks = try? decoder.decode([CatalogSong].self, from: data) { return tracks }
        if let album = try? decoder.decode(CatalogFinderAlbum.self, from: data) { return album.tracks }
        if let resolution = try? decoder.decode(URLResolution.self, from: data) { return resolution.tracks }
        if let results = try? decoder.decode(CatalogSearchResults.self, from: data) { return results.tracks }
        if let song = try? decoder.decode(CatalogSong.self, from: data) { return [song] }
        throw APIError.decodingFailure
    }

    func preview(artist: String, title: String, duration: Double? = nil, session: DeviceSession) async throws -> URL? {
        let validDuration = duration.map { $0.isFinite && $0 >= 0 } ?? true
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              artist.count <= 200, title.count <= 300, validDuration else {
            throw CatalogAPIError.invalidInput
        }
        let response = try await get(PreviewResponse.self, path: "/api/preview", query: [
            URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "title", value: title),
            duration.map { URLQueryItem(name: "duration", value: String($0)) }
        ].compactMap { $0 }, session: session, requiresExternalCatalog: true)
        guard let value = URL(string: response.previewURL), value.scheme?.lowercased() == "https" else { return nil }
        return value
    }

    func finderSearch(query: String, limit: Int = 25, session: DeviceSession) async throws -> CatalogSearchResults {
        try validate(query: query)
        try validate(limit: limit)
        return try await get(CatalogSearchResults.self, path: "/api/finder/search", query: [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: String(limit))
        ], session: session, requiresDiscoverCapability: true)
    }

    func finderArtist(id: String, language: String = "en", session: DeviceSession) async throws -> CatalogFinderArtist {
        try validate(deezerID: id)
        return try await get(CatalogFinderArtist.self, path: "/api/finder/artist", query: [
            URLQueryItem(name: "artist_id", value: id), URLQueryItem(name: "lang", value: language)
        ], session: session, requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func finderArtistSongs(id: String, name: String, session: DeviceSession) async throws -> CatalogSearchResults {
        try validate(deezerID: id)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogAPIError.invalidInput }
        return try await get(CatalogSearchResults.self, path: "/api/finder/artist/songs", query: [
            URLQueryItem(name: "artist_id", value: id), URLQueryItem(name: "name", value: name)
        ], session: session, requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func finderArtistAlbums(id: String, session: DeviceSession) async throws -> [CatalogAlbum] {
        try validate(deezerID: id)
        return try await get([CatalogAlbum].self, path: "/api/finder/artist/albums", query: [
            URLQueryItem(name: "artist_id", value: id)
        ], session: session, requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func finderAlbumTrackCounts(ids: [String], session: DeviceSession) async throws -> [String: Int] {
        guard !ids.isEmpty, ids.count <= 50, ids.allSatisfy(isDecimalID) else { throw CatalogAPIError.invalidInput }
        return try await get([String: Int].self, path: "/api/finder/albums/track_counts", query: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ], session: session, requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func finderAlbum(id: String, session: DeviceSession) async throws -> CatalogFinderAlbum {
        try validate(deezerID: id)
        return try await get(CatalogFinderAlbum.self, path: "/api/finder/album", query: [
            URLQueryItem(name: "album_id", value: id)
        ], session: session, requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func charts(limit: Int = 25, session: DeviceSession) async throws -> CatalogCharts {
        try validate(limit: limit)
        return try await get(CatalogCharts.self, path: "/api/discover/chart", query: [
            URLQueryItem(name: "limit", value: String(limit))
        ], session: session, requiresDiscoverCapability: true)
    }

    func similar(artist: String = "", track: String = "", limit: Int = 20, session: DeviceSession) async throws -> CatalogSimilarResults {
        try validate(limit: limit)
        guard (!artist.isEmpty || !track.isEmpty), artist.count <= 200, track.count <= 200 else { throw CatalogAPIError.invalidInput }
        return try await get(CatalogSimilarResults.self, path: "/api/similar/tracks", query: [
            URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "track", value: track),
            URLQueryItem(name: "limit", value: String(limit))
        ], session: session, requiresDiscoverCapability: true)
    }

    func discover(library: [CatalogLibraryArtist], session: DeviceSession) async throws -> CatalogDiscoverResults {
        try await post(CatalogDiscoverResults.self, path: "/api/discover", body: DiscoverBody(library: library), session: session,
                       requiresDiscoverCapability: true)
    }

    func deezerCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistNames: [String], session: DeviceSession) async throws -> CatalogCollectionsResults {
        let body = CollectionsBody(library: library, albums: albums, playlistNames: playlistNames)
        return try await post(CatalogCollectionsResults.self, path: "/api/discover/collections/deezer", body: body, session: session,
                              requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func spotifyCollections(library: [CatalogLibraryArtist], albums: [CatalogLibraryAlbum], playlistIDs: [String], shown: [String], session: DeviceSession) async throws -> CatalogCollectionsResults {
        let body = SpotifyCollectionsBody(library: library, albums: albums, playlistIDs: playlistIDs, shown: shown)
        return try await post(CatalogCollectionsResults.self, path: "/api/discover/collections/spotify", body: body, session: session,
                              requiresExternalCatalog: true, requiresDiscoverCapability: true)
    }

    func blockedArtists(session: DeviceSession) async throws -> [CatalogBlockedArtist] {
        try await get([CatalogBlockedArtist].self, path: "/api/discover/blocked", session: session,
                      requiresDiscoverCapability: true)
    }

    func blockArtist(name: String, session: DeviceSession) async throws -> CatalogBlockedArtist {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogAPIError.invalidInput }
        return try await post(CatalogBlockedArtist.self, path: "/api/discover/blocked", body: BlockArtistBody(name: name), session: session,
                              requiresDiscoverCapability: true)
    }

    func unblockArtist(name: String, session: DeviceSession) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogAPIError.invalidInput }
        _ = try await request(path: "/api/discover/blocked", method: "DELETE", query: [URLQueryItem(name: "name", value: name)],
                              session: session, requiresDiscoverCapability: true)
    }

    private func get<Value: Decodable>(
        _ type: Value.Type, path: String, query: [URLQueryItem] = [], session: DeviceSession,
        requiresExternalCatalog: Bool = false, requiresDiscoverCapability: Bool = false
    ) async throws -> Value {
        let data = try await request(path: path, query: query, session: session,
                                     requiresExternalCatalog: requiresExternalCatalog,
                                     requiresDiscoverCapability: requiresDiscoverCapability)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingFailure }
    }

    private func post<Value: Decodable, Body: Encodable>(
        _ type: Value.Type, path: String, body: Body, session: DeviceSession,
        requiresExternalCatalog: Bool = false, requiresDiscoverCapability: Bool = false
    ) async throws -> Value {
        let encoded: Data
        do { encoded = try JSONEncoder().encode(body) }
        catch { throw APIError.decodingFailure }
        let data = try await request(path: path, method: "POST", body: encoded, session: session,
                                     requiresExternalCatalog: requiresExternalCatalog,
                                     requiresDiscoverCapability: requiresDiscoverCapability)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingFailure }
    }

    private func request(
        path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
        session: DeviceSession, requiresExternalCatalog: Bool = false, requiresDiscoverCapability: Bool = false,
        timeoutInterval: TimeInterval = 60
    ) async throws -> Data {
        try Task.checkCancellation()
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let info = try await serverInfo(session: session)
        if requiresDiscoverCapability && !info.supportsDiscover { throw CatalogAPIError.featureUnavailable }
        if requiresExternalCatalog && info.isLibraryOnly { throw CatalogAPIError.libraryOnly }

        guard var components = URLComponents(url: address.url(for: path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidAddress
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try Task.checkCancellation()
        return try await APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
            .send(request, to: address)
    }

    private func validate(query: String) throws {
        guard query.count <= 500 else { throw CatalogAPIError.invalidInput }
    }

    private func validate(limit: Int) throws {
        guard (1...50).contains(limit) else { throw CatalogAPIError.invalidInput }
    }

    private func validate(deezerID: String) throws {
        guard isDecimalID(deezerID) else { throw CatalogAPIError.invalidInput }
    }

    private func isDecimalID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private struct DiscoverBody: Encodable { let library: [CatalogLibraryArtist] }
    private struct CollectionsBody: Encodable {
        let library: [CatalogLibraryArtist]
        let albums: [CatalogLibraryAlbum]
        let playlistNames: [String]
        enum CodingKeys: String, CodingKey { case library, albums; case playlistNames = "playlist_names" }
    }
    private struct SpotifyCollectionsBody: Encodable {
        let library: [CatalogLibraryArtist]
        let albums: [CatalogLibraryAlbum]
        let playlistIDs: [String]
        let shown: [String]
        enum CodingKeys: String, CodingKey { case library, albums, shown; case playlistIDs = "playlist_ids" }
    }
    private struct BlockArtistBody: Encodable { let name: String }
    private struct PreviewResponse: Decodable {
        let previewURL: String
        enum CodingKeys: String, CodingKey { case previewURL = "preview_url" }
    }
}
