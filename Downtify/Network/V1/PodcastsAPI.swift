import Foundation

struct PodcastShow: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let author: String?
    let description: String?
    let artworkURL: String?
    let episodeCount: Int?
    let downloadedCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, author, description
        case artworkURL = "artwork_url"
        case episodeCount = "episode_count"
        case downloadedCount = "downloaded_count"
    }
}

struct PodcastEpisode: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let showID: Int
    let title: String
    let description: String?
    let publishedAt: String?
    let durationSeconds: Double?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let enclosureURL: String?
    let filename: String?
    let positionSeconds: Double?
    let played: Bool?

    var isDownloaded: Bool { filename.map { !$0.isEmpty } ?? false }

    // Publisher media is separate from the authenticated Downtify server.
    var publisherAudioURL: URL? {
        guard let enclosureURL, let url = URL(string: enclosureURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, filename, played
        case showID = "show_id"
        case publishedAt = "published_at"
        case durationSeconds = "duration_seconds"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case enclosureURL = "enclosure_url"
        case positionSeconds = "position_seconds"
    }
}

struct PodcastShowEpisodes: Decodable, Sendable {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
}

enum PodcastAPIError: Error, Equatable {
    case unsupported
}

protocol PodcastPlaybackServing {
    func stream(episode: PodcastEpisode, session: DeviceSession) async throws -> PlaybackStream
    func savePlayback(episodeID: Int, position: Double, played: Bool?,
                      session: DeviceSession) async throws -> PodcastEpisode
}

struct PodcastsAPI: PodcastPlaybackServing {
    var transport: any HTTPDataLoading = ConnectionHTTPTransport()

    func shows(session: DeviceSession) async throws -> [PodcastShow] {
        try await get("/api/podcasts/shows", session: session)
    }

    func episodes(showID: Int, session: DeviceSession) async throws -> PodcastShowEpisodes {
        try await get("/api/podcasts/shows/\(showID)/episodes", session: session)
    }

    func download(episodeID: Int, session: DeviceSession) async throws -> PodcastEpisode {
        try await send("/api/podcasts/episodes/\(episodeID)/download", method: "POST", session: session)
    }

    func savePlayback(episodeID: Int, position: Double, played: Bool? = nil,
                      session: DeviceSession) async throws -> PodcastEpisode {
        struct Body: Encodable {
            let positionSeconds: Double
            let played: Bool?

            enum CodingKeys: String, CodingKey {
                case played
                case positionSeconds = "position_seconds"
            }
        }
        return try await send("/api/podcasts/episodes/\(episodeID)/playback", method: "PUT",
                              body: try JSONEncoder().encode(Body(positionSeconds: position, played: played)), session: session)
    }

    func stream(episode: PodcastEpisode, session: DeviceSession) async throws -> PlaybackStream {
        let (client, address) = try await verifiedServer(session)
        if let filename = episode.filename, !filename.isEmpty {
            let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
                throw PlaybackFailure.invalidStream
            }
            let source = RangeSource(client: client, address: address,
                                     url: address.url(for: "/downloads/\(filename)"), token: session.token)
            do {
                let (_, initial) = try await source.fetch(0...1)
                let type = try PlaybackStreamResolver.mediaType(initial.mediaType, filename: filename)
                return PlaybackStream(contentType: type.uti, fileExtension: type.ext, length: initial.length,
                                      quality: .original, availableQualities: [.original]) { range in
                    let (data, response) = try await source.fetch(range, validator: initial.validator)
                    guard response.length == initial.length, response.mediaType == initial.mediaType,
                          response.validator == initial.validator else { throw PlaybackFailure.invalidStream }
                    return data
                }
            } catch APIError.httpStatus(404, _) {
                // A server copy may have expired since the episode list was fetched.
            }
        }
        guard let url = episode.publisherAudioURL else { throw PlaybackFailure.invalidStream }
        return PlaybackStream(contentType: "", fileExtension: "", length: 0, quality: .original,
                              availableQualities: [.original], directURL: url) { _ in
            throw PlaybackFailure.invalidStream
        }
    }

    private func verifiedServer(_ session: DeviceSession) async throws -> (APIClient, ServerAddress) {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let info = try await client.serverInfo(at: address)
        try Task.checkCancellation()
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        guard info.supportsPodcasts else { throw PodcastAPIError.unsupported }
        return (client, address)
    }

    private func get<T: Decodable>(_ path: String, session: DeviceSession) async throws -> T {
        try await send(path, method: "GET", session: session)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data? = nil,
                                    session: DeviceSession) async throws -> T {
        let (client, address) = try await verifiedServer(session)
        var request = URLRequest(url: address.url(for: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try await client.send(request, to: address)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decodingFailure }
    }
}
