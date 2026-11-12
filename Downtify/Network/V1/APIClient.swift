import Foundation

struct ServerAddress: Equatable {
    let baseURL: URL

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.invalidAddress }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw APIError.invalidAddress
        }

        components.scheme = scheme
        components.host = host.lowercased()
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = normalizedPath.isEmpty ? "" : "/\(normalizedPath)"
        guard let url = components.url else { throw APIError.invalidAddress }
        baseURL = url
    }

    var usesInsecureHTTP: Bool { baseURL.scheme == "http" }

    func url(for path: String) -> URL {
        baseURL.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}

enum APIError: Error, Equatable {
    case invalidAddress
    case insecureTransportConsentRequired
    case invalidResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case incompatibleProduct(String)
    case unsupportedAPIVersion(Int)
    case decodingFailure
    case transportFailure
}

protocol HTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoading {}

struct APIClient {
    private let session: any HTTPDataLoading
    private let allowsInsecureRequests: Bool

    init(
        session: any HTTPDataLoading = URLSession.shared,
        allowsInsecureRequests: Bool = false
    ) {
        self.session = session
        self.allowsInsecureRequests = allowsInsecureRequests
    }

    func serverInfo(at address: ServerAddress, allowsCellularAccess: Bool = true) async throws -> MobileAPIV1.ServerInfoDTO {
        var request = URLRequest(url: address.url(for: MobileAPIV1.serverInfoPath))
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellularAccess
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await load(request, address: address, isPublicServerInfo: true)
        let info: MobileAPIV1.ServerInfoDTO
        do {
            info = try JSONDecoder().decode(MobileAPIV1.ServerInfoDTO.self, from: data)
        } catch {
            throw APIError.decodingFailure
        }
        guard info.product == "Downtify" else { throw APIError.incompatibleProduct(info.product) }
        guard info.apiVersion <= MobileAPIV1.maximumAPIVersion else {
            throw APIError.unsupportedAPIVersion(info.apiVersion)
        }
        return info
    }

    func send(_ request: URLRequest, to address: ServerAddress) async throws -> Data {
        try await sendWithResponse(request, to: address).0
    }

    func sendWithResponse(_ request: URLRequest, to address: ServerAddress) async throws -> (Data, HTTPURLResponse) {
        try await load(request, address: address, isPublicServerInfo: false)
    }

    func sendWithErrorBody(_ request: URLRequest, to address: ServerAddress) async throws -> (Data, HTTPURLResponse) {
        try await load(request, address: address, isPublicServerInfo: false, allowsHTTPErrorResponses: true)
    }

    private func load(
        _ request: URLRequest,
        address: ServerAddress,
        isPublicServerInfo: Bool,
        allowsHTTPErrorResponses: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        if address.usesInsecureHTTP && !isPublicServerInfo && !allowsInsecureRequests {
            throw APIError.insecureTransportConsentRequired
        }
        do {
            let (data, response) = try await session.data(for: request)
            let route = diagnosticRoute(request)
            guard let http = response as? HTTPURLResponse else {
                await NetworkOperationCoordinator.shared.recordFailure("Invalid HTTP response · \(route)")
                throw APIError.invalidResponse
            }
            guard allowsHTTPErrorResponses || (200..<300).contains(http.statusCode) else {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                await NetworkOperationCoordinator.shared.recordFailure("HTTP \(http.statusCode) · \(route)")
                throw APIError.httpStatus(http.statusCode, retryAfter: retryAfter)
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            // Never include the request URL, headers, or underlying error in diagnostics.
            let route = diagnosticRoute(request)
            await NetworkOperationCoordinator.shared.recordFailure("Network transport failed · \(route)")
            throw APIError.transportFailure
        }
    }
}

private func diagnosticRoute(_ request: URLRequest) -> String {
    let components = (request.url?.path ?? "").split(separator: "/")
    let path: String
    if components.count >= 4, components[0] == "api", components[1] == "v1", components[2] == "tracks" {
        let suffix = components.dropFirst(4).joined(separator: "/")
        path = "/api/v1/tracks/:id" + (suffix.isEmpty ? "" : "/\(suffix)")
    } else {
        path = request.url?.path ?? "unknown route"
    }
    return "\(request.httpMethod ?? "GET") \(path)"
}
