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
    private let preservesTransportErrors: Bool

    init(transport: any HTTPDataLoading = ConnectionHTTPTransport(), preservesTransportErrors: Bool = false) {
        self.transport = transport
        self.preservesTransportErrors = preservesTransportErrors
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
        let info = try await APIClient(session: transport, preservesTransportErrors: preservesTransportErrors).serverInfo(at: address)
        try Task.checkCancellation()
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        return address
    }
}

/// Lyrics contract: GET /api/v1/tracks/{id}/lyrics returns optional LRC and plain text.
struct TrackLyrics: Equatable, Sendable {
    let synced: String
    let plain: String

    var lines: [LyricLine] { LyricLine.parse(synced) }
    var hasContent: Bool { !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct LyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String

    static func parse(_ lrc: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = regex.matches(in: raw, range: range)
            guard let lastMatch = matches.last,
                  let lastTagRange = Range(lastMatch.range, in: raw) else { continue }
            let text = String(raw[lastTagRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: raw),
                      let secondsRange = Range(match.range(at: 2), in: raw),
                      let minutes = Double(raw[minutesRange]), let seconds = Double(raw[secondsRange]) else { continue }
                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: raw) {
                    let digits = String(raw[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                result.append(LyricLine(time: minutes * 60 + seconds + fraction,
                                        text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

struct TrackLyricsAPI {
    var transport: any HTTPDataLoading = ConnectionHTTPTransport()

    func fetch(trackID: String, session: DeviceSession) async throws -> TrackLyrics? {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let info = try await client.serverInfo(at: address)
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        guard info.supportsLyrics else { return nil }
        let base = address.url(for: "/api/v1/tracks")
        let encodedID = trackID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
        guard let encodedID else { throw APIError.invalidAddress }
        let url = base.appendingPathComponent(encodedID).appendingPathComponent("lyrics")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await client.send(request, to: address)
        do { return try JSONDecoder().decode(LyricsDTO.self, from: data).model }
        catch { throw APIError.decodingFailure }
    }
}

private struct LyricsDTO: Decodable {
    let synced: String?
    let plain: String?
    var model: TrackLyrics { TrackLyrics(synced: synced ?? "", plain: plain ?? "") }
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
