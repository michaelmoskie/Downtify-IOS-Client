import Foundation

struct LibraryPlaylist: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let displayName: String?
    let liked: Bool?
    var favorite: Bool?
    let trackIDs: [String]
    let cover: String?
    let owner: String?
    let mine: Bool?
    let visibility: String?
    let sharedWithMe: Bool?

    var id: String { name }
    var title: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name }

    enum CodingKeys: String, CodingKey {
        case name, liked, favorite, cover, owner, mine, visibility
        case displayName = "display_name"
        case trackIDs = "track_ids"
        case sharedWithMe = "shared_with_me"
    }
}

protocol LibraryCollectionsFetching {
    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist]
    func likes(for session: DeviceSession) async throws -> [String]
    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws
    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws
}

struct LibraryCollectionsAPI: LibraryCollectionsFetching {
    private let transport: any HTTPDataLoading

    init(transport: any HTTPDataLoading = ConnectionHTTPTransport()) {
        self.transport = transport
    }

    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist] {
        try await read([LibraryPlaylist].self, path: "/api/v1/playlists", session: session)
    }

    func likes(for session: DeviceSession) async throws -> [String] {
        try await read(Likes.self, path: "/api/v1/likes", session: session).trackIDs
    }

    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws {
        let body = try JSONEncoder().encode(LikeChange(trackID: trackID, liked: liked))
        _ = try await request("/api/v1/likes", body: body, session: session)
    }

    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws {
        let body = try JSONEncoder().encode(FavoriteChange(name: name, favorite: favorite))
        _ = try await request("/api/v1/playlists/favorite", body: body, session: session)
    }

    private func read<T: Decodable>(_ type: T.Type, path: String, session: DeviceSession) async throws -> T {
        let data = try await request(path, session: session)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingFailure }
    }

    private func request(_ path: String, body: Data? = nil, session: DeviceSession) async throws -> Data {
        let address = try await LibraryAPIClient(transport: transport).verifiedAddress(for: session)
        var request = URLRequest(url: address.url(for: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
            .send(request, to: address)
    }

    private struct Likes: Decodable {
        let trackIDs: [String]
        enum CodingKeys: String, CodingKey { case trackIDs = "track_ids" }
    }

    private struct LikeChange: Encodable {
        let trackID: String
        let liked: Bool
        enum CodingKeys: String, CodingKey {
            case trackID = "track_id"
            case liked
        }
    }

    private struct FavoriteChange: Encodable {
        let name: String
        let favorite: Bool
    }
}
