import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum PlaybackCodec: String, Codable, CaseIterable, Sendable {
    case opus, aac, mp3

    static var supportsOggOpus: Bool {
        AVURLAsset.isPlayableExtendedMIMEType("audio/ogg; codecs=\"opus\"")
    }

    var suggestedBitrates: [Int] {
        switch self {
        case .opus: [96, 128, 160, 256]
        case .aac: [128, 192, 256]
        case .mp3: [128, 192, 320]
        }
    }
}

enum PlaybackQuality: Equatable, Codable, Sendable {
    case original
    case transcoded(PlaybackCodec, bitrate: Int)
}

struct PlaybackQualities: Equatable, Codable, Sendable {
    var wifi: PlaybackQuality = .original
    var cellular: PlaybackQuality = PlaybackCodec.supportsOggOpus
        ? .transcoded(.opus, bitrate: 160) : .transcoded(.aac, bitrate: 128)

    func preferred(on network: PlaybackNetwork) -> PlaybackQuality {
        network == .cellular ? cellular : wifi
    }

    static func available(on server: MobileAPIV1.ServerInfoDTO,
                          supportsOggOpus: Bool = PlaybackCodec.supportsOggOpus) -> [PlaybackQuality] {
        guard let transcoding = server.capabilities?.transcoding, transcoding.available == true else {
            return [.original]
        }
        let formats = transcoding.formats ?? []
        let bitrates = transcoding.bitrates ?? []
        return [.original] + PlaybackCodec.allCases.flatMap { codec -> [PlaybackQuality] in
            guard codec != .opus || supportsOggOpus else { return [] }
            guard formats.isEmpty || formats.contains(codec.rawValue) else { return [] }
            return codec.suggestedBitrates
                .filter { bitrates.isEmpty || bitrates.contains($0) }
                .map { .transcoded(codec, bitrate: $0) }
        }
    }
}

enum PlaybackNetwork: Sendable {
    case wifiOrWired, cellular, unavailable
}

enum PlaybackFailure: Error, Equatable, Sendable {
    case signedOut
    case differentServer
    case insecureAddress
    case unauthorized
    case network
    case invalidStream
    case unsupportedFormat
    case media
    case audioSession
}

struct PlaybackStream: Sendable {
    let contentType: String
    let fileExtension: String
    let length: Int64
    let quality: PlaybackQuality
    let availableQualities: [PlaybackQuality]
    let fileURL: URL?
    let directURL: URL?
    let read: @Sendable (ClosedRange<Int64>) async throws -> Data

    init(contentType: String, fileExtension: String, length: Int64, quality: PlaybackQuality,
         availableQualities: [PlaybackQuality], fileURL: URL? = nil, directURL: URL? = nil,
         read: @escaping @Sendable (ClosedRange<Int64>) async throws -> Data) {
        self.contentType = contentType
        self.fileExtension = fileExtension
        self.length = length
        self.quality = quality
        self.availableQualities = availableQualities
        self.fileURL = fileURL
        self.directURL = directURL
        self.read = read
    }
}

protocol PlaybackStreamResolving {
    func resolve(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream
    func warmTranscode(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws
    func resolve(catalogSong: CatalogSong, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream
    func prefetch(catalogSong: CatalogSong, session: DeviceSession) async throws
}

extension PlaybackStreamResolving {
    func warmTranscode(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws {}
    func resolve(catalogSong: CatalogSong, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        throw PlaybackFailure.invalidStream
    }
    func prefetch(catalogSong: CatalogSong, session: DeviceSession) async throws {}
}

struct PlaybackStreamResolver: PlaybackStreamResolving {
    private let transport: any HTTPDataLoading
    private let cache: PlaybackCache?
    private let offline: (any OfflinePlaybackProviding)?

    init(transport: any HTTPDataLoading = ConnectionHTTPTransport(), cache: PlaybackCache? = nil,
         offline: (any OfflinePlaybackProviding)? = nil) {
        self.transport = transport
        self.cache = cache
        self.offline = offline
    }

    func resolve(track: LibraryTrack, quality preference: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        if let saved = await offline?.offlineStream(trackID: track.id, session: session) { return saved }
        let (client, address, choices, _) = try await verifiedServer(for: session)
        let quality = choices.contains(preference) ? preference : .original
        let url = try Self.streamURL(address: address, trackID: track.id, quality: quality)
        let source = RangeSource(client: client, address: address, url: url, token: session.token)
        let (_, response) = try await source.fetch(0...1)
        let type = try Self.mediaType(response.mediaType, filename: track.file)
        let representation = PlaybackCache.Representation(
            scope: LibraryScope(serverID: session.serverID, username: session.username, deviceID: session.deviceID),
            url: url, validator: response.validator ?? UUID().uuidString, length: response.length, mediaType: response.mediaType
        )
        let fetch: @Sendable (ClosedRange<Int64>) async throws -> Data = { range in
            let (data, current) = try await source.fetch(range, validator: response.validator)
            guard current.length == response.length, current.mediaType == response.mediaType,
                  current.validator == response.validator else { throw PlaybackFailure.invalidStream }
            return data
        }
        return PlaybackStream(contentType: type.uti, fileExtension: type.ext, length: response.length,
                              quality: response.servedOriginal ? .original : quality, availableQualities: choices) { range in
            guard range.lowerBound >= 0, range.upperBound < response.length else { throw PlaybackFailure.invalidStream }
            if let cache {
                return try await cache.read(range, representation: representation, fetch: fetch)
            }
            return try await fetch(range)
        }
    }

    func resolve(catalogSong: CatalogSong, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        guard catalogSong.source.lowercased() != "library" else { throw CatalogAPIError.libraryOnly }
        let (client, address, choices, libraryOnly) = try await verifiedServer(for: session)
        guard !libraryOnly else { throw CatalogAPIError.libraryOnly }
        let (videoID, duration) = try await catalogVideo(catalogSong, session: session)
        guard duration.isFinite, duration >= 0 else { throw PlaybackFailure.invalidStream }
        let url = try Self.catalogStreamURL(address: address, videoID: videoID, duration: duration)
        let source = RangeSource(client: client, address: address, url: url, token: session.token)
        let (_, response) = try await source.fetch(0...1)
        let type = try Self.mediaType(response.mediaType, filename: catalogSong.file ?? "track.mp3")
        // Catalog entries have their own cache account namespace and URL route, separate from /api/v1 library IDs.
        let catalogScope = LibraryScope(serverID: session.serverID,
                                        username: session.username.map { "catalog:\($0)" } ?? "catalog:device:\(session.deviceID)",
                                        deviceID: "catalog:\(session.deviceID)")
        let representation = PlaybackCache.Representation(scope: catalogScope, url: url,
            validator: response.validator ?? UUID().uuidString, length: response.length, mediaType: response.mediaType)
        let fetch: @Sendable (ClosedRange<Int64>) async throws -> Data = { range in
            let (data, current) = try await source.fetch(range, validator: response.validator)
            guard current.length == response.length, current.mediaType == response.mediaType,
                  current.validator == response.validator else { throw PlaybackFailure.invalidStream }
            return data
        }
        return PlaybackStream(contentType: type.uti, fileExtension: type.ext, length: response.length,
                              quality: .original, availableQualities: choices) { range in
            guard range.lowerBound >= 0, range.upperBound < response.length else { throw PlaybackFailure.invalidStream }
            if let cache { return try await cache.read(range, representation: representation, fetch: fetch) }
            return try await fetch(range)
        }
    }

    func prefetch(catalogSong: CatalogSong, session: DeviceSession) async throws {
        guard catalogSong.source.lowercased() != "library" else { return }
        let (client, address, _, libraryOnly) = try await verifiedServer(for: session)
        guard !libraryOnly else { return }
        let (videoID, _) = try await catalogVideo(catalogSong, session: session)
        try Task.checkCancellation()
        var request = URLRequest(url: address.url(for: "/api/stream/prefetch"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CatalogPrefetchBody(videoID: videoID))
        _ = try await client.send(request, to: address)
    }

    func warmTranscode(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws {
        guard case .transcoded = quality,
              await offline?.offlineStream(trackID: track.id, session: session) == nil else { return }
        let (client, address, choices, _) = try await verifiedServer(for: session)
        guard choices.contains(quality) else { return }
        let url = try Self.streamURL(address: address, trackID: track.id, quality: quality)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        _ = try await client.send(request, to: address)
    }

    private func verifiedServer(for session: DeviceSession) async throws -> (APIClient, ServerAddress, [PlaybackQuality], Bool) {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else { throw PlaybackFailure.insecureAddress }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let server = try await client.serverInfo(at: address)
        try Task.checkCancellation()
        guard server.serverID == session.serverID else { throw PlaybackFailure.differentServer }
        return (client, address, PlaybackQualities.available(on: server), server.isLibraryOnly)
    }

    private func catalogVideo(_ song: CatalogSong, session: DeviceSession) async throws -> (String, Double) {
        if let direct = Self.catalogYouTubeID(song) {
            return (direct, song.duration ?? 0)
        }
        let query = [song.artist, song.title].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { throw CatalogAPIError.invalidInput }
        let candidates = try await CatalogAPI(transport: transport).searchSongs(query: query, session: session)
        guard let match = candidates.first(where: { candidate in
            guard (Self.catalogYouTubeID(candidate)) != nil else { return false }
            guard let wanted = song.duration, let found = candidate.duration else { return true }
            return wanted.isFinite && found.isFinite && abs(wanted - found) <= 10
        }), let videoID = Self.catalogYouTubeID(match) else {
            throw PlaybackFailure.invalidStream
        }
        return (videoID, song.duration ?? match.duration ?? 0)
    }

    private static func catalogYouTubeID(_ song: CatalogSong) -> String? {
        if let id = validYouTubeID(song.youtubeID) { return id }
        guard song.source == "youtube_music" else { return nil }
        return validYouTubeID(song.songID)
    }

    private static func validYouTubeID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 11,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return value
    }

    static func catalogStreamURL(address: ServerAddress, videoID: String, duration: Double) throws -> URL {
        guard validYouTubeID(videoID) != nil, duration.isFinite, duration >= 0,
              var components = URLComponents(url: address.url(for: "/api/stream/file"), resolvingAgainstBaseURL: false) else {
            throw PlaybackFailure.invalidStream
        }
        components.queryItems = [URLQueryItem(name: "video_id", value: videoID),
                                 URLQueryItem(name: "duration", value: String(duration))]
        guard let url = components.url else { throw PlaybackFailure.invalidStream }
        return url
    }

    static func streamURL(address: ServerAddress, trackID: String, quality: PlaybackQuality) throws -> URL {
        // Track IDs are path components, not user-provided routes.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !trackID.isEmpty, trackID.unicodeScalars.allSatisfy(allowed.contains),
              var components = URLComponents(url: address.url(for: "/api/v1/tracks/\(trackID)/stream"),
                                             resolvingAgainstBaseURL: false) else {
            throw PlaybackFailure.invalidStream
        }
        if case let .transcoded(format, bitrate) = quality {
            components.queryItems = [URLQueryItem(name: "format", value: format.rawValue),
                                     URLQueryItem(name: "bitrate", value: String(bitrate))]
        }
        guard let url = components.url else { throw PlaybackFailure.invalidStream }
        return url
    }

    static func mediaType(_ mime: String, filename: String) throws -> (uti: String, ext: String) {
        let ext: String
        switch mime {
        case "audio/mpeg", "audio/mp3": ext = "mp3"
        case "audio/mp4", "audio/x-m4a", "video/mp4": ext = "m4a"
        case "audio/aac", "audio/aacp": ext = "aac"
        case "audio/flac", "audio/x-flac": ext = "flac"
        case "audio/ogg", "application/ogg", "audio/opus":
            guard PlaybackCodec.supportsOggOpus else { throw PlaybackFailure.unsupportedFormat }
            ext = "ogg"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": ext = "wav"
        case "audio/aiff", "audio/x-aiff": ext = "aiff"
        case "application/octet-stream", "":
            ext = (filename as NSString).pathExtension.lowercased()
            guard ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif"].contains(ext) else {
                throw PlaybackFailure.unsupportedFormat
            }
        default: throw PlaybackFailure.unsupportedFormat
        }
        guard let type = UTType(filenameExtension: ext) else { throw PlaybackFailure.unsupportedFormat }
        return (type.identifier, ext)
    }
}

private struct CatalogPrefetchBody: Encodable {
    let videoID: String
    enum CodingKeys: String, CodingKey { case videoID = "video_id" }
}

struct RangeSource {
    struct Information {
        let length: Int64
        let mediaType: String
        let validator: String?
        let servedOriginal: Bool
    }

    let client: APIClient
    let address: ServerAddress
    let url: URL
    let token: String

    func fetch(_ requested: ClosedRange<Int64>, validator: String? = nil) async throws -> (Data, Information) {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(requested.lowerBound)-\(requested.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(validator, forHTTPHeaderField: "If-Range")

        let (data, response) = try await client.sendWithResponse(request, to: address)
        guard response.statusCode == 206,
              let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes "),
              let slash = header.firstIndex(of: "/"),
              let length = Int64(header[header.index(after: slash)...]), length > requested.lowerBound else {
            throw PlaybackFailure.invalidStream
        }
        let end = min(requested.upperBound, length - 1)
        guard header[header.index(header.startIndex, offsetBy: 6)..<slash] == "\(requested.lowerBound)-\(end)",
              Int64(data.count) == end - requested.lowerBound + 1 else {
            throw PlaybackFailure.invalidStream
        }
        let mime = response.mimeType?.lowercased() ?? ""
        let tag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let information = Information(length: length, mediaType: mime, validator: tag,
                                      servedOriginal: response.value(forHTTPHeaderField: "X-Downtify-Transcoded") == "no")
        return (data, information)
    }
}
