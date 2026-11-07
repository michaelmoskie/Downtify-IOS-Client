import Foundation

struct OfflineDownloadSource {
    let request: URLRequest
    let background: Bool
    let media: OfflineMedia
}

protocol OfflineDownloadPreparing {
    func prepare(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession,
                 wifiOnly: Bool) async throws -> OfflineDownloadSource
}

struct OfflineDownloadAPI: OfflineDownloadPreparing {
    var transport: any HTTPDataLoading = ConnectionHTTPTransport()

    func prepare(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession,
                 wifiOnly: Bool) async throws -> OfflineDownloadSource {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else { throw PlaybackFailure.insecureAddress }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let info = try await client.serverInfo(at: address, allowsCellularAccess: !wifiOnly)
        try Task.checkCancellation()
        guard info.serverID == session.serverID else { throw PlaybackFailure.differentServer }
        guard PlaybackQualities.available(on: info).contains(quality) else { throw PlaybackFailure.unsupportedFormat }

        let route = "/api/v1/tracks/\(track.id)/stream"
        let streamURL = try PlaybackStreamResolver.streamURL(address: address, trackID: track.id, quality: quality)
        guard var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else {
            throw PlaybackFailure.invalidStream
        }
        let items = (components.queryItems ?? []) + [URLQueryItem(name: "download", value: "true")]
        components.queryItems = items
        guard let url = components.url else { throw PlaybackFailure.invalidStream }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.allowsCellularAccess = !wifiOnly
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "HEAD"
        let (_, response) = try await client.sendWithResponse(request, to: address)
        let mime = response.mimeType?.lowercased() ?? ""
        let type = try PlaybackStreamResolver.mediaType(mime, filename: track.file)
        guard response.statusCode == 200, response.expectedContentLength > 0 else {
            throw PlaybackFailure.invalidStream
        }
        let media = OfflineMedia(length: response.expectedContentLength, mime: mime, type: type.uti,
                                 fileExtension: type.ext, etag: Self.strongETag(response),
                                 quality: response.value(forHTTPHeaderField: "X-Downtify-Transcoded") == "no"
                                    ? .original : quality)
        request.httpMethod = "GET"

        // Background URLSession follows redirects. Give it only a scoped read URL, never the pairing token.
        guard !address.usesInsecureHTTP, info.capabilities?.signedURLs == true else {
            return OfflineDownloadSource(request: request, background: false, media: media)
        }
        var sign = URLRequest(url: address.url(for: "/api/v1/sign"))
        sign.httpMethod = "POST"
        sign.allowsCellularAccess = !wifiOnly
        sign.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        sign.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
        sign.httpBody = try JSONEncoder().encode(SignRequest(items: [.init(path: route, params: params)], ttl: 86_400))
        let data = try await client.send(sign, to: address)
        guard let path = try JSONDecoder().decode(SignResponse.self, from: data).urls.first,
              let signed = URLComponents(string: path), signed.path == route, signed.scheme == nil,
              signed.host == nil, signed.fragment == nil, let query = signed.queryItems,
              query.count == params.count + 3,
              Set(query.map(\.name)).count == query.count,
              Set(query.map(\.name)) == Set(params.keys).union(["exp", "kid", "sig"]),
              query.allSatisfy({ item in
                  guard let value = item.value, !value.isEmpty else { return false }
                  return params[item.name].map { $0 == value } ?? true
              }) else { throw PlaybackFailure.invalidStream }
        components.percentEncodedQuery = signed.percentEncodedQuery
        guard let signedURL = components.url else { throw PlaybackFailure.invalidStream }
        request.url = signedURL
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        return OfflineDownloadSource(request: request, background: true, media: media)
    }

    static func strongETag(_ response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
    }

    private struct SignRequest: Encodable {
        struct Item: Encodable {
            let path: String
            let params: [String: String]
        }

        let items: [Item]
        let ttl: Int
    }

    private struct SignResponse: Decodable {
        let urls: [String]
    }
}
