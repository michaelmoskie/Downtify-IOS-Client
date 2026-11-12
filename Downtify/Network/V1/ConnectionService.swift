import Foundation

struct PairingPayload: Equatable, CustomDebugStringConvertible {
    let address: ServerAddress
    let serverID: String
    let code: String

    var debugDescription: String { "PairingPayload" }

    init(_ value: String) throws {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "downtify", components.host?.lowercased() == "pair",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else {
            throw ConnectionError.invalidPairingPayload
        }

        func item(_ name: String) -> String? {
            let matches = components.queryItems?.filter { $0.name == name }
            guard matches?.count == 1, let value = matches?.first?.value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }

        guard let url = item("url"), url.contains("://"), let address = try? ServerAddress(url),
              let serverID = item("sid"), let code = item("code") else {
            throw ConnectionError.invalidPairingPayload
        }
        self.address = address
        self.serverID = serverID
        self.code = code
    }
}

enum ConnectionError: Error, Equatable {
    case invalidPairingPayload
    case differentServer
    case wrongCode
    case wrongCredentials
    case passwordSignInUnavailable
    case rateLimited(retryAfter: TimeInterval)
}

struct ConnectionTarget {
    let address: ServerAddress
    let info: MobileAPIV1.ServerInfoDTO

    fileprivate init(address: ServerAddress, info: MobileAPIV1.ServerInfoDTO) {
        self.address = address
        self.info = info
    }
}

enum DeviceSessionStatus: Equatable {
    case signedOut
    case active
    case revoked
}

actor ConnectionService {
    private let transport: any HTTPDataLoading
    private let store: any DeviceSessionStoring
    private var sessionGeneration = 0
    private var sessionObservers: [UUID: AsyncStream<DeviceSession?>.Continuation] = [:]

    init(
        transport: any HTTPDataLoading = ConnectionHTTPTransport(),
        store: any DeviceSessionStoring = KeychainSessionStore()
    ) {
        self.transport = transport
        self.store = store
    }

    func probe(_ input: String) async throws -> ConnectionTarget {
        try await probe(ServerAddress(input))
    }

    func probe(_ discovered: DiscoveredServer) async throws -> ConnectionTarget {
        let target = try await probe(discovered.address)
        if let advertisedID = discovered.serverID, advertisedID != target.info.serverID {
            throw ConnectionError.differentServer
        }
        return target
    }

    func pair(
        code: String, at target: ConnectionTarget, deviceName: String,
        consentingTo insecureAddress: ServerAddress? = nil
    ) async throws -> DeviceSession {
        let body = PairRequest(code: code.trimmingCharacters(in: .whitespacesAndNewlines), deviceName: deviceName)
        return try await authenticate("/api/auth/pair", target: target, body: body,
                                      unauthorized: .wrongCode, insecureAddress: insecureAddress)
    }

    func pair(
        _ payload: PairingPayload, deviceName: String,
        consentingTo insecureAddress: ServerAddress? = nil
    ) async throws -> DeviceSession {
        let generation = sessionGeneration
        let target = try await probe(payload.address)
        try ensureCurrent(generation)
        guard target.info.serverID == payload.serverID else { throw ConnectionError.differentServer }
        return try await pair(code: payload.code, at: target, deviceName: deviceName, consentingTo: insecureAddress)
    }

    func signIn(
        username: String, password: String, at target: ConnectionTarget, deviceName: String,
        consentingTo insecureAddress: ServerAddress? = nil
    ) async throws -> DeviceSession {
        guard target.info.supportsPasswordSignIn else { throw ConnectionError.passwordSignInUnavailable }
        let body = PasswordRequest(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                   password: password, deviceName: deviceName)
        return try await authenticate("/api/auth/token", target: target, body: body,
                                      unauthorized: .wrongCredentials, insecureAddress: insecureAddress)
    }

    func restoreSession() throws -> DeviceSession? {
        try store.load()
    }

    func sessionUpdates() throws -> AsyncStream<DeviceSession?> {
        let current = try store.load()
        let id = UUID()
        let (stream, continuation) = AsyncStream<DeviceSession?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sessionObservers[id] = continuation
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSessionObserver(id) }
        }
        return stream
    }

    func signOut() throws {
        sessionGeneration += 1
        try store.clear()
        publishSession(nil)
    }

    /// Use after a rejected WebSocket handshake to distinguish revocation from proxy or network failures.
    func verifySession(expected: DeviceSession? = nil) async throws -> DeviceSessionStatus {
        guard let session = try store.load() else { return .signedOut }
        guard expected == nil || expected == session else { throw CancellationError() }
        let generation = sessionGeneration
        let address = try ServerAddress(session.baseAddress)
        let target = try await probe(address)
        try ensureCurrent(generation)
        guard target.info.serverID == session.serverID else { throw ConnectionError.differentServer }

        var request = URLRequest(url: address.url(for: "/api/auth/status"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let isActive: Bool
        do {
            let data = try await client.send(request, to: address)
            let status = try decode(AuthStatus.self, from: data)
            isActive = status.via == "device" && status.signedIn
        } catch APIError.httpStatus(401, _) {
            isActive = false
        }
        try ensureCurrent(generation)
        if isActive { return .active }
        try signOut()
        return .revoked
    }

    private func probe(_ address: ServerAddress) async throws -> ConnectionTarget {
        let info = try await APIClient(session: transport).serverInfo(at: address)
        try Task.checkCancellation()
        guard !info.serverID.isEmpty else { throw APIError.invalidResponse }
        return ConnectionTarget(address: address, info: info)
    }

    private func authenticate<Body: Encodable>(
        _ path: String, target: ConnectionTarget, body: Body,
        unauthorized: ConnectionError, insecureAddress: ServerAddress?
    ) async throws -> DeviceSession {
        sessionGeneration += 1
        let generation = sessionGeneration
        let allowsInsecureHTTP = target.address.usesInsecureHTTP && insecureAddress == target.address
        let client = APIClient(session: transport, allowsInsecureRequests: allowsInsecureHTTP)
        var request = URLRequest(url: target.address.url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        do {
            data = try await client.send(request, to: target.address)
        } catch {
            try ensureCurrent(generation)
            switch error {
            case APIError.httpStatus(401, _): throw unauthorized
            case APIError.httpStatus(409, _) where unauthorized == .wrongCredentials:
                throw ConnectionError.passwordSignInUnavailable
            case APIError.httpStatus(429, let retryAfter):
                let wait = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                throw ConnectionError.rateLimited(retryAfter: wait ?? 60)
            default: throw error
            }
        }
        try ensureCurrent(generation)
        let response = try decode(AuthResponse.self, from: data)
        guard !response.token.isEmpty, !response.device.id.isEmpty else { throw APIError.invalidResponse }
        if let returnedID = response.server?.id, !returnedID.isEmpty, returnedID != target.info.serverID {
            throw ConnectionError.differentServer
        }

        let name = [target.info.name, response.server?.name].compactMap { $0 }.first { !$0.isEmpty }
        let session = DeviceSession(
            baseAddress: target.address.baseURL.absoluteString,
            serverID: target.info.serverID,
            serverName: name ?? target.address.baseURL.host() ?? "Downtify",
            deviceID: response.device.id,
            username: response.user?.username,
            role: response.user?.role,
            token: response.token,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        try store.save(session)
        sessionGeneration += 1
        publishSession(session)
        return session
    }

    private func publishSession(_ session: DeviceSession?) {
        for observer in sessionObservers.values { observer.yield(session) }
    }

    private func removeSessionObserver(_ id: UUID) {
        sessionObservers.removeValue(forKey: id)
    }

    private func ensureCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingFailure
        }
    }
}

private struct PairRequest: Encodable {
    let code: String
    let deviceName: String
    let platform = "ios"

    enum CodingKeys: String, CodingKey {
        case code, platform
        case deviceName = "device_name"
    }
}

private struct PasswordRequest: Encodable {
    let username: String
    let password: String
    let deviceName: String
    let platform = "ios"

    enum CodingKeys: String, CodingKey {
        case username, password, platform
        case deviceName = "device_name"
    }
}

private struct AuthResponse: Decodable {
    struct Device: Decodable {
        let id: String
    }

    struct Server: Decodable {
        let id: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case id = "server_id"
            case name
        }
    }

    struct User: Decodable {
        let username: String?
        let role: String?
    }

    let token: String
    let device: Device
    let server: Server?
    let user: User?
}

private struct AuthStatus: Decodable {
    let via: String?
    let signedIn: Bool

    enum CodingKeys: String, CodingKey {
        case via
        case signedIn = "signed_in"
    }
}

/// Bind credentials to the probed address and keep web cookies and HTTP credentials out of the device session.
final class ConnectionHTTPTransport: HTTPDataLoading {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await NetworkOperationCoordinator.shared.withOperation {
            try await session.data(for: request)
        }
    }
}

enum NetworkOperationPriority: Int, Sendable {
    case background = 0
    case userFacing = 1
}

enum NetworkOperationContext {
    @TaskLocal static var priority: NetworkOperationPriority = .background
}

struct NetworkOperationSnapshot: Equatable, Sendable {
    let active: Int
    let maximum: Int
    let queued: Int
    let foregroundActive: Int
    let backgroundActive: Int
    let foregroundQueued: Int
    let backgroundQueued: Int
    let recentFailures: [String]
}

actor NetworkOperationCoordinator {
    static let shared = NetworkOperationCoordinator(limit: 2)
    private static let failuresDefaultsKey = "debug.networkOverlay.recentFailures"

    private struct Waiter {
        let id: UUID
        let priority: NetworkOperationPriority
        let order: UInt64
        let onPreempt: (@Sendable () -> Void)?
        let continuation: CheckedContinuation<UUID, Error>
    }

    private struct ActiveOperation {
        let priority: NetworkOperationPriority
        let onPreempt: (@Sendable () -> Void)?
        var preemptionRequested = false
    }

    private let limit: Int
    private var active: [UUID: ActiveOperation] = [:]
    private var order: UInt64 = 0
    private var waiters: [Waiter] = []
    private var recentFailures = UserDefaults.standard.stringArray(forKey: failuresDefaultsKey) ?? []

    init(limit: Int = 2) { self.limit = max(1, limit) }

    var queuedOperationCount: Int { waiters.count }

    func snapshot() -> NetworkOperationSnapshot {
        let foregroundActive = active.values.filter { $0.priority == .userFacing }.count
        let foregroundQueued = waiters.filter { $0.priority == .userFacing }.count
        return NetworkOperationSnapshot(active: active.count, maximum: limit, queued: waiters.count,
                                        foregroundActive: foregroundActive,
                                        backgroundActive: active.count - foregroundActive,
                                        foregroundQueued: foregroundQueued,
                                        backgroundQueued: waiters.count - foregroundQueued,
                                        recentFailures: recentFailures)
    }

    func recordFailure(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        recentFailures.append("\(timestamp)  \(message)")
        if recentFailures.count > 5 { recentFailures.removeFirst(recentFailures.count - 5) }
        UserDefaults.standard.set(recentFailures, forKey: Self.failuresDefaultsKey)
    }

    func withOperation<T>(priority: NetworkOperationPriority? = nil,
                          operation: () async throws -> T) async throws -> T {
        let lease = try await acquire(priority: priority ?? NetworkOperationContext.priority)

        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(lease)
            return result
        } catch {
            release(lease)
            throw error
        }
    }

    func acquire(priority: NetworkOperationPriority, onPreempt: (@Sendable () -> Void)? = nil) async throws -> UUID {
        let id = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if active.count < limit && waiters.isEmpty {
                    active[id] = ActiveOperation(priority: priority, onPreempt: onPreempt)
                    continuation.resume(returning: id)
                } else {
                    order &+= 1
                    waiters.append(Waiter(id: id, priority: priority, order: order,
                                          onPreempt: onPreempt, continuation: continuation))
                    if priority == .userFacing { requestBackgroundPreemption() }
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
        if Task.isCancelled { release(lease); throw CancellationError() }
        return lease
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release(_ id: UUID) {
        guard active.removeValue(forKey: id) != nil else { return }
        if !waiters.isEmpty {
            let index = waiters.indices.max {
                let lhs = waiters[$0], rhs = waiters[$1]
                return lhs.priority == rhs.priority ? lhs.order > rhs.order : lhs.priority.rawValue < rhs.priority.rawValue
            }!
            let waiter = waiters.remove(at: index)
            active[waiter.id] = ActiveOperation(priority: waiter.priority, onPreempt: waiter.onPreempt)
            waiter.continuation.resume(returning: waiter.id)
        }
    }

    private func requestBackgroundPreemption() {
        for id in active.keys {
            guard var operation = active[id], operation.priority == .background,
                  !operation.preemptionRequested, let onPreempt = operation.onPreempt else { continue }
            operation.preemptionRequested = true
            active[id] = operation
            onPreempt()
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
