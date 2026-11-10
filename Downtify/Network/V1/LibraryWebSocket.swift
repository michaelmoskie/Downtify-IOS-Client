import Foundation

enum LibraryLiveEvent: Equatable {
    case connected
    case libraryChanged
    case collectionsChanged
    case musicPolicyChanged

    static func decode(_ message: URLSessionWebSocketTask.Message) -> Self? {
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: return nil
        }
        guard let event = try? JSONDecoder().decode(WireEvent.self, from: data) else { return nil }
        switch event.type {
        case "library_changed": return .libraryChanged
        case "playlists_changed", "likes": return .collectionsChanged
        case "music_policy_changed": return .musicPolicyChanged
        default: return nil
        }
    }

    private struct WireEvent: Decodable { let type: String }
}

enum LibrarySocketError: Error, Equatable {
    case refused
    case disconnected
}

protocol LibraryEventStreaming {
    func events(for session: DeviceSession) async throws -> AsyncThrowingStream<LibraryLiveEvent, Error>
}

struct LibraryWebSocket: LibraryEventStreaming {
    let api: LibraryAPIClient
    private let clientID = UUID().uuidString

    func events(for session: DeviceSession) async throws -> AsyncThrowingStream<LibraryLiveEvent, Error> {
        let address = try await api.verifiedAddress(for: session)
        guard var components = URLComponents(url: address.url(for: "/api/ws"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidAddress
        }
        components.scheme = address.usesInsecureHTTP ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        guard let url = components.url else { throw APIError.invalidAddress }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        return Self.open(request)
    }

    private static func open(_ request: URLRequest) -> AsyncThrowingStream<LibraryLiveEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let delegate = LibrarySocketDelegate(continuation: continuation)
            let transport = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let socket = transport.webSocketTask(with: request)
            let receiver = Task {
                socket.resume()
                defer { transport.invalidateAndCancel() }
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        if let event = LibraryLiveEvent.decode(message) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    let status = (socket.response as? HTTPURLResponse)?.statusCode
                    let refused = socket.closeCode.rawValue == 4401 || status == 401 || status == 403
                    continuation.finish(throwing: refused ? LibrarySocketError.refused : LibrarySocketError.disconnected)
                }
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

private final class LibrarySocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private let continuation: AsyncThrowingStream<LibraryLiveEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<LibraryLiveEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(.connected)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let error = closeCode.rawValue == 4401 ? LibrarySocketError.refused : LibrarySocketError.disconnected
        continuation.finish(throwing: error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
