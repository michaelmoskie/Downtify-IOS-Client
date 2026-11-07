import Foundation

/// Jobs are server work. A completed job becomes available to the library feed, not the offline store.
struct ServerDownloadQueue {
    struct Job: Decodable, Equatable {
        struct Song: Decodable, Equatable {
            let id: String?
            let url: String?
            let title: String?
            let artist: String?
        }

        let song: Song
        let status: String
        let progress: Double?
        let message: String?
        let filename: String?
        let position: Int?
        let provider: String?
    }

    struct Status: Decodable, Equatable {
        let paused: Bool
        let state: String
        let active: Int
    }

    var transport: any HTTPDataLoading = ConnectionHTTPTransport()
    var verifySession: ((DeviceSession) async -> Void)?

    func jobs(session: DeviceSession) async throws -> [Job] {
        try await send("/api/queue", session: session)
    }

    func status(session: DeviceSession) async throws -> Status {
        try await send("/api/queue/state", session: session)
    }

    func requestTrack(link: URL, session: DeviceSession) async throws -> String {
        guard ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
              link.host != nil, link.user == nil, link.password == nil else { throw APIError.invalidAddress }
        return try await send("/api/download/url", method: "POST",
                              query: [.init(name: "url", value: link.absoluteString)], timeout: 600, session: session)
    }

    private func send<Response: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                                           timeout: TimeInterval = 30, session: DeviceSession) async throws -> Response {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else {
            throw APIError.insecureTransportConsentRequired
        }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let server = try await client.serverInfo(at: address)
        guard server.serverID == session.serverID else { throw PlaybackFailure.differentServer }
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
        do {
            let data = try await client.send(request, to: address)
            guard let value = try? JSONDecoder().decode(Response.self, from: data) else { throw APIError.decodingFailure }
            return value
        } catch APIError.httpStatus(401, let retryAfter) {
            await verifySession?(session)
            throw APIError.httpStatus(401, retryAfter: retryAfter)
        }
    }
}
