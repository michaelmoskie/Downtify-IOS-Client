import Foundation

struct LibraryPage: Equatable, Sendable {
    let cursor: Int64
    let full: Bool
    let tracks: [LibraryTrack]
    let deleted: [String]
}

enum LibraryFeedResult: Equatable, Sendable {
    case unchanged
    case page(LibraryPage, etag: String?)
}

protocol LibraryFeedFetching {
    func fetch(since cursor: Int64, etag: String?, refresh: Bool, session: DeviceSession) async throws -> LibraryFeedResult
}

struct LibraryAPIClient: LibraryFeedFetching {
    private let transport: any HTTPDataLoading

    init(transport: any HTTPDataLoading = ConnectionHTTPTransport()) {
        self.transport = transport
    }

    func fetch(
        since cursor: Int64, etag: String?, refresh: Bool, session: DeviceSession
    ) async throws -> LibraryFeedResult {
        let address = try await verifiedAddress(for: session)
        guard var components = URLComponents(url: address.url(for: "/api/v1/library"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidAddress
        }
        components.queryItems = [URLQueryItem(name: "since", value: String(cursor))]
        if refresh { components.queryItems?.append(URLQueryItem(name: "refresh", value: "true")) }
        guard let url = components.url else { throw APIError.invalidAddress }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if !refresh { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.sendWithResponse(request, to: address)
        } catch APIError.httpStatus(304, _) {
            return .unchanged
        }

        do {
            let page = try JSONDecoder().decode(PageDTO.self, from: data)
            return .page(page.model, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch {
            throw APIError.decodingFailure
        }
    }

    func verifiedAddress(for session: DeviceSession) async throws -> ServerAddress {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let info = try await APIClient(session: transport).serverInfo(at: address)
        try Task.checkCancellation()
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        return address
    }
}

private struct PageDTO: Decodable {
    let cursor: Int64
    let full: Bool
    let tracks: [TrackDTO]
    let deleted: [String]

    var model: LibraryPage {
        LibraryPage(cursor: cursor, full: full, tracks: tracks.map(\.model), deleted: deleted)
    }
}

private struct TrackDTO: Decodable {
    let id: String
    let file: String?
    let title: String?
    let artist: String?
    let artists: [String]?
    let album: String?
    let albumArtist: String?
    let albumID: String?
    let artistID: String?
    let trackNumber: Int?
    let year: String?
    let duration: Double?
    let codec: String?
    let bitrate: Int?
    let sampleRate: Int?
    let channels: Int?
    let size: Int64?
    let added: Int64?
    let hasCover: Bool?
    let isExplicit: Bool?
    let playlists: [String]?

    enum CodingKeys: String, CodingKey {
        case id, file, title, artist, artists, album, year, duration, codec, bitrate, channels, size, added, playlists
        case albumArtist = "album_artist"
        case albumID = "album_id"
        case artistID = "artist_id"
        case trackNumber = "track_number"
        case sampleRate = "sample_rate"
        case hasCover = "has_cover"
        case isExplicit = "explicit"
    }

    var model: LibraryTrack {
        LibraryTrack(
            id: id, file: file ?? "", title: title ?? "", artist: artist ?? "", artists: artists ?? [],
            album: album ?? "", albumArtist: albumArtist ?? "", albumID: albumID ?? "", artistID: artistID ?? "",
            trackNumber: trackNumber ?? 0, year: year ?? "", duration: duration ?? 0, codec: codec ?? "",
            bitrate: bitrate ?? 0, sampleRate: sampleRate ?? 0, channels: channels ?? 0,
            size: size ?? 0, added: added ?? 0, hasCover: hasCover ?? false,
            isExplicit: isExplicit ?? false, playlists: playlists ?? []
        )
    }
}
