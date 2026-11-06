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
    let read: @Sendable (ClosedRange<Int64>) async throws -> Data
}

protocol PlaybackStreamResolving {
    func resolve(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream
    func warmTranscode(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws
}

extension PlaybackStreamResolving {
    func warmTranscode(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws {}
}

struct PlaybackStreamResolver: PlaybackStreamResolving {
    private let transport: any HTTPDataLoading
    private let cache: PlaybackCache?

    init(transport: any HTTPDataLoading = ConnectionHTTPTransport(), cache: PlaybackCache? = nil) {
        self.transport = transport
        self.cache = cache
    }

    func resolve(track: LibraryTrack, quality preference: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        let (client, address, choices) = try await verifiedServer(for: session)
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

    func warmTranscode(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws {
        guard case .transcoded = quality else { return }
        let (client, address, choices) = try await verifiedServer(for: session)
        guard choices.contains(quality) else { return }
        let url = try Self.streamURL(address: address, trackID: track.id, quality: quality)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        _ = try await client.send(request, to: address)
    }

    private func verifiedServer(for session: DeviceSession) async throws -> (APIClient, ServerAddress, [PlaybackQuality]) {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else { throw PlaybackFailure.insecureAddress }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let server = try await client.serverInfo(at: address)
        try Task.checkCancellation()
        guard server.serverID == session.serverID else { throw PlaybackFailure.differentServer }
        return (client, address, PlaybackQualities.available(on: server))
    }

    private static func streamURL(address: ServerAddress, trackID: String, quality: PlaybackQuality) throws -> URL {
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

    private static func mediaType(_ mime: String, filename: String) throws -> (uti: String, ext: String) {
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

private struct RangeSource {
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
