import Foundation

/// Jobs are server work. A completed job becomes available to the library feed, not the offline store.
struct ServerDownloadQueue {
    struct Job: Decodable, Equatable, Identifiable {
        struct Song: Decodable, Equatable {
            let id: String?
            let url: String?
            let title: String?
            let artist: String?
            let artists: [String]

            enum CodingKeys: String, CodingKey { case id, songID = "song_id", url, title, name, artist, artists }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(String.self, forKey: .songID) ?? container.decodeIfPresent(String.self, forKey: .id)
                url = try container.decodeIfPresent(String.self, forKey: .url)
                title = try container.decodeIfPresent(String.self, forKey: .name) ?? container.decodeIfPresent(String.self, forKey: .title)
                artists = try container.decodeIfPresent([String].self, forKey: .artists) ?? []
                artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? artists.joined(separator: ", ")
            }
        }

        let song: Song
        let status: String
        let progress: Double?
        let message: String?
        let filename: String?
        let position: Int?
        let provider: String?

        var id: String { song.id ?? song.url ?? "\(song.title ?? "job")-\(filename ?? status)" }
    }

    struct Status: Decodable, Equatable {
        let paused: Bool
        let state: String
        let active: Int
    }

    struct BatchOptions: Equatable, Sendable {
        var playlistURL: String?
        var playlistName: String?
        var coverURL: String?
        var generateM3U: Bool

        init(playlistURL: String? = nil, playlistName: String? = nil, coverURL: String? = nil, generateM3U: Bool = false) {
            self.playlistURL = playlistURL
            self.playlistName = playlistName
            self.coverURL = coverURL
            self.generateM3U = generateM3U
        }
    }

    struct BatchResponse: Decodable, Equatable {
        let jobIDs: [String]
        let count: Int

        enum CodingKeys: String, CodingKey { case jobIDs = "job_ids", count }
    }

    var transport: any HTTPDataLoading = ConnectionHTTPTransport()
    var verifySession: ((DeviceSession) async -> Void)?

    func jobs(session: DeviceSession) async throws -> [Job] {
        try await send("/api/queue", session: session)
    }

    func status(session: DeviceSession) async throws -> Status {
        try await send("/api/queue/state", session: session)
    }

    /// Submits a pasted HTTP(S) link. The long server-side lookup is a single POST; callers must
    /// not automatically replay it after cancellation or timeout because the server may have queued it.
    func requestTrack(link: URL, session: DeviceSession) async throws -> String {
        guard ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
              link.host != nil, link.user == nil, link.password == nil else { throw APIError.invalidAddress }
        return try await send("/api/download/url", method: "POST",
                              query: [.init(name: "url", value: link.absoluteString)], timeout: 600, session: session)
    }

    /// Sends the complete provider row as JSON. `CatalogSong.encode` emits its retained raw payload,
    /// including provider identifiers and fields not modeled by the app.
    func requestTrack(song: CatalogSong, session: DeviceSession) async throws -> String {
        guard !song.url.isEmpty else { throw CatalogAPIError.invalidInput }
        let body = try JSONEncoder().encode(song)
        return try await send("/api/download/url", method: "POST",
                              query: [.init(name: "url", value: song.url)], body: body,
                              timeout: 600, session: session)
    }

    func requestBatch(songs: [CatalogSong], options: BatchOptions = .init(), session: DeviceSession) async throws -> BatchResponse {
        guard !songs.isEmpty, songs.count <= 500 else { throw CatalogAPIError.invalidInput }
        let body = try JSONEncoder().encode(BatchBody(songs: songs, options: options))
        return try await send("/api/download/batch", method: "POST", body: body, timeout: 600, session: session)
    }

    /// Album lookup is deliberately limited to the server's supported YouTube Music album URL forms.
    /// The endpoint only reports successful items, so callers need an expected tracklist to infer partial completion.
    func requestAlbum(url: String, session: DeviceSession) async throws -> [String: String] {
        guard Self.isYouTubeMusicAlbumURL(url) else { throw CatalogAPIError.invalidInput }
        return try await send("/api/download/album", method: "POST",
                              query: [.init(name: "url", value: url)], timeout: 600, session: session)
    }

    private struct BatchBody: Encodable {
        let songs: [CatalogSong]
        let playlistURL: String?
        let playlistName: String?
        let coverURL: String?
        let generateM3U: Bool

        enum CodingKeys: String, CodingKey {
            case songs
            case playlistURL = "playlist_url"
            case playlistName = "playlist_name"
            case coverURL = "cover_url"
            case generateM3U = "generate_m3u"
        }

        init(songs: [CatalogSong], options: BatchOptions) {
            self.songs = songs
            playlistURL = options.playlistURL
            playlistName = options.playlistName
            coverURL = options.coverURL
            generateM3U = options.generateM3U
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(songs, forKey: .songs)
            try container.encodeIfPresent(playlistURL, forKey: .playlistURL)
            try container.encodeIfPresent(playlistName, forKey: .playlistName)
            try container.encodeIfPresent(coverURL, forKey: .coverURL)
            try container.encode(generateM3U, forKey: .generateM3U)
        }
    }

    private func send<Response: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                                           body: Data? = nil, timeout: TimeInterval = 30,
                                           session: DeviceSession) async throws -> Response {
        try Task.checkCancellation()
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let server = try await client.serverInfo(at: address)
        try Task.checkCancellation()
        guard server.serverID == session.serverID else { throw PlaybackFailure.differentServer }
        guard !server.isLibraryOnly else { throw CatalogAPIError.libraryOnly }
        guard var components = URLComponents(url: address.url(for: path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidAddress
        }
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw APIError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let data = try await client.send(request, to: address)
            guard let value = try? JSONDecoder().decode(Response.self, from: data) else { throw APIError.decodingFailure }
            return value
        } catch APIError.httpStatus(401, let retryAfter) {
            await verifySession?(session)
            throw APIError.httpStatus(401, retryAfter: retryAfter)
        }
    }

    static func isYouTubeMusicAlbumURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "music.youtube.com",
              components.user == nil, components.password == nil else { return false }
        let browse = components.path.range(of: #"^/browse/MPREb_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        let playlist = components.queryItems?.first(where: { $0.name == "list" })?.value
            .map { $0.range(of: #"^OLAK5uy_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil } ?? false
        return browse || playlist
    }
}
