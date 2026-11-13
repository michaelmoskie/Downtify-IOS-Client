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
    let manual: Bool?
    let canEditTracks: Bool?
    let visibility: String?
    let sharedWithMe: Bool?
    let sharedWith: [String]?
    let editors: [String]?

    var id: String { name }
    var title: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name }

    enum CodingKeys: String, CodingKey {
        case name, liked, favorite, cover, owner, mine, manual, visibility, editors
        case displayName = "display_name"
        case trackIDs = "track_ids"
        case sharedWithMe = "shared_with_me"
        case canEditTracks = "can_edit_tracks"
        case sharedWith = "shared_with"
    }
}

protocol LibraryCollectionsFetching {
    func playlists(for session: DeviceSession) async throws -> [LibraryPlaylist]
    func likes(for session: DeviceSession) async throws -> [String]
    func supportsPlaylistEditing(for session: DeviceSession) async throws -> Bool
    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws
    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws
    func createPlaylist(name: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO
    func renamePlaylist(name: String, to newName: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO
    func editPlaylistTracks(
        name: String, add: [String]?, remove: [String]?, removeEntries: [PlaylistTrackEditsRequestDTO.RemovalEntry]?,
        allowDuplicates: Bool?, session: DeviceSession
    ) async throws -> PlaylistMutationResponseDTO
    func reorderPlaylist(name: String, trackIDs: [String], session: DeviceSession) async throws -> PlaylistMutationResponseDTO
}

extension LibraryCollectionsFetching {
    func supportsPlaylistEditing(for session: DeviceSession) async throws -> Bool { false }

    // Existing read-only/test implementations can keep conforming while mutation support is added.
    func createPlaylist(name: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO { throw APIError.transportFailure }
    func renamePlaylist(name: String, to newName: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO { throw APIError.transportFailure }
    func editPlaylistTracks(
        name: String, add: [String]?, remove: [String]?, removeEntries: [PlaylistTrackEditsRequestDTO.RemovalEntry]?,
        allowDuplicates: Bool?, session: DeviceSession
    ) async throws -> PlaylistMutationResponseDTO { throw APIError.transportFailure }
    func reorderPlaylist(name: String, trackIDs: [String], session: DeviceSession) async throws -> PlaylistMutationResponseDTO { throw APIError.transportFailure }
}

enum PlaylistWriteError: Error { case acceptedResponseUnreadable }

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

    func supportsPlaylistEditing(for session: DeviceSession) async throws -> Bool {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let info = try await APIClient(session: transport).serverInfo(at: address)
        try Task.checkCancellation()
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        return info.supportsPlaylistEditing
    }

    func setLiked(_ liked: Bool, trackID: String, session: DeviceSession) async throws {
        let body = try JSONEncoder().encode(LikeChange(trackID: trackID, liked: liked))
        _ = try await request("/api/v1/likes", body: body, session: session)
    }

    func setFavorite(_ favorite: Bool, name: String, session: DeviceSession) async throws {
        let body = try JSONEncoder().encode(FavoriteChange(name: name, favorite: favorite))
        _ = try await request("/api/v1/playlists/favorite", body: body, session: session)
    }

    func createPlaylist(name: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO {
        let body = try JSONEncoder().encode(PlaylistCreateRequestDTO(name: name))
        return try decodeWrite(await request("/api/v1/playlists", method: "POST", body: body, session: session))
    }

    func renamePlaylist(name: String, to newName: String, session: DeviceSession) async throws -> PlaylistMutationResponseDTO {
        let body = try JSONEncoder().encode(PlaylistRenameRequestDTO(name: name, newName: newName))
        return try decodeWrite(await request("/api/v1/playlists/rename", method: "POST", body: body, session: session))
    }

    func editPlaylistTracks(
        name: String, add: [String]? = nil, remove: [String]? = nil,
        removeEntries: [PlaylistTrackEditsRequestDTO.RemovalEntry]? = nil,
        allowDuplicates: Bool? = nil, session: DeviceSession
    ) async throws -> PlaylistMutationResponseDTO {
        let referenceCount = (add?.count ?? 0) + (remove?.count ?? 0) + (removeEntries?.count ?? 0)
        guard referenceCount <= 10_000 else { throw APIError.httpStatus(400, retryAfter: nil) }
        let requestBody = PlaylistTrackEditsRequestDTO(
            name: name, add: add, remove: remove, removeEntries: removeEntries, allowDuplicates: allowDuplicates
        )
        return try decodeWrite(await request(
            "/api/v1/playlists/tracks", method: "POST", body: JSONEncoder().encode(requestBody), session: session
        ))
    }

    func reorderPlaylist(name: String, trackIDs: [String], session: DeviceSession) async throws -> PlaylistMutationResponseDTO {
        guard trackIDs.count <= 10_000 else { throw APIError.httpStatus(400, retryAfter: nil) }
        let body = try JSONEncoder().encode(PlaylistOrderRequestDTO(name: name, trackIDs: trackIDs))
        return try decodeWrite(await request("/api/v1/playlists/order", method: "PUT", body: body, session: session))
    }

    private func decodeWrite(_ data: Data) throws -> PlaylistMutationResponseDTO {
        do { return try JSONDecoder().decode(PlaylistMutationResponseDTO.self, from: data) }
        catch { throw PlaylistWriteError.acceptedResponseUnreadable }
    }

    private func read<T: Decodable>(_ type: T.Type, path: String, session: DeviceSession) async throws -> T {
        let data = try await request(path, session: session)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingFailure }
    }

    private func request(_ path: String, body: Data? = nil, session: DeviceSession) async throws -> Data {
        try await request(path, method: body == nil ? "GET" : "PUT", body: body, session: session)
    }

    private func request(_ path: String, method: String, body: Data?, session: DeviceSession) async throws -> Data {
        let address = try await LibraryAPIClient(transport: transport).verifiedAddress(for: session)
        var request = URLRequest(url: address.url(for: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let body {
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

// Music trash is an admin device-token exception documented by the server's mobile contract.
// Keep the wire layer explicit: the capability endpoint, not a guessed /server/info flag,
// decides whether this pairing may manage trash.
struct TrashCapabilityDTO: Decodable, Equatable {
    let enabled: Bool
    let canManage: Bool
    let retentionDays: Int
    enum CodingKeys: String, CodingKey {
        case enabled
        case canManage = "can_manage"
        case retentionDays = "retention_days"
    }
    var available: Bool { enabled && canManage }
}

struct TrashItemDTO: Decodable, Identifiable, Equatable {
    struct Metadata: Decodable, Equatable {
        let title: String?
        let artist: String?
        let album: String?
        let codec: String?
    }
    let id: String
    let file: String
    let trackID: String?
    let metadata: Metadata
    let state: String
    let size: Int64
    let expiresAt: Double?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case id, file, metadata, state, size, error
        case trackID = "track_id"
        case expiresAt = "expires_at"
    }
}

struct TrashPreviewDTO: Decodable, Equatable {
    let confirmation: String
    let items: [TrashItemDTO]
}

struct TrashListingDTO: Decodable, Equatable {
    let items: [TrashItemDTO]
    let total: Int
    let size: Int64
}

enum TrashAPIError: Error, Equatable {
    case httpStatus(Int, code: String?)
}

struct TrashAPI {
    private let transport: any HTTPDataLoading
    init(transport: any HTTPDataLoading = ConnectionHTTPTransport()) { self.transport = transport }

    func capabilities(session: DeviceSession) async throws -> TrashCapabilityDTO {
        try await get("/api/v1/library/trash/capabilities", session: session)
    }
    func preview(trackIDs: [String], session: DeviceSession) async throws -> (String, TrashPreviewDTO) {
        let start: PreviewStart = try await post("/api/v1/library/trash/preview", body: TrackSelection(trackIDs: trackIDs), session: session)
        for _ in 0..<1800 {
            try Task.checkCancellation()
            let status: PreviewStatus = try await get("/api/v1/library/trash/preview/\(start.requestID)", session: session)
            if status.state == "ready", let preview = status.preview { return (start.requestID, preview) }
            try await Task.sleep(for: .seconds(1))
        }
        throw APIError.transportFailure
    }
    func confirm(_ confirmation: String, session: DeviceSession) async throws -> [String] {
        let result: Confirmed = try await post("/api/v1/library/trash/confirm", body: Confirmation(confirmation: confirmation), session: session)
        return result.ids
    }
    func listing(offset: Int = 0, limit: Int = 50, search: String = "", session: DeviceSession) async throws -> TrashListingDTO {
        var components = URLComponents(url: try address(session).url(for: "/api/v1/library/trash"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "offset", value: String(max(0, offset))),
                                 URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
                                 URLQueryItem(name: "search", value: search)]
        return try await request(url: components.url!, method: "GET", body: nil, session: session)
    }
    func exclusions(session: DeviceSession) async throws -> [TrashItemDTO] {
        let result: Exclusions = try await get("/api/v1/library/trash/exclusions", session: session)
        return result.items
    }
    func restore(ids: [String], session: DeviceSession) async throws { let _: Empty = try await post("/api/v1/library/trash/restore", body: IDs(ids: ids), session: session) }
    func retry(ids: [String], session: DeviceSession) async throws { let _: Empty = try await post("/api/v1/library/trash/retry", body: IDs(ids: ids), session: session) }
    func allowDownload(ids: [String], session: DeviceSession) async throws { let _: Empty = try await post("/api/v1/library/trash/allow-download", body: IDs(ids: ids), session: session) }

    private func address(_ session: DeviceSession) throws -> ServerAddress { try ServerAddress(session.baseAddress) }
    private func verifyAdmin(_ session: DeviceSession) throws {
        guard session.role?.lowercased() == "admin" else { throw APIError.httpStatus(403, retryAfter: nil) }
    }
    private func get<T: Decodable>(_ path: String, session: DeviceSession) async throws -> T {
        if path != "/api/v1/library/trash/capabilities" { try verifyAdmin(session) }
        let result: T = try await request(url: address(session).url(for: path), method: "GET", body: nil, session: session)
        return result
    }
    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, session: DeviceSession) async throws -> T {
        try verifyAdmin(session)
        let result: T = try await request(url: address(session).url(for: path), method: "POST",
                                          body: try JSONEncoder().encode(body), session: session)
        return result
    }
    private func request<T: Decodable>(url: URL, method: String, body: Data?, session: DeviceSession) async throws -> T {
        let serverAddress = try address(session)
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let info = try await client.serverInfo(at: serverAddress)
        guard info.serverID == session.serverID else { throw ConnectionError.differentServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await client.sendWithErrorBody(request, to: serverAddress)
        guard (200..<300).contains(response.statusCode) else {
            let code = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).detail.code
            throw TrashAPIError.httpStatus(response.statusCode, code: code)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.decodingFailure }
    }
    private struct TrackSelection: Encodable { let trackIDs: [String]; enum CodingKeys: String, CodingKey { case trackIDs = "track_ids" } }
    private struct Confirmation: Encodable { let confirmation: String }
    private struct IDs: Encodable { let ids: [String] }
    private struct Confirmed: Decodable { let ids: [String] }
    private struct PreviewStart: Decodable { let requestID: String; enum CodingKeys: String, CodingKey { case requestID = "request_id" } }
    private struct PreviewStatus: Decodable { let state: String; let preview: TrashPreviewDTO? }
    private struct Exclusions: Decodable { let items: [TrashItemDTO] }
    private struct Empty: Decodable {}
    private struct ErrorEnvelope: Decodable { let detail: Detail; struct Detail: Decodable { let code: String? } }
}
