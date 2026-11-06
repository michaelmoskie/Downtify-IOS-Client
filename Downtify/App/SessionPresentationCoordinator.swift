import Combine
import Foundation

/// Routes the app from the connection flow to the library without exposing session credentials.
@MainActor
final class SessionPresentationCoordinator: ObservableObject {
    struct ServerSummary: Equatable {
        let name: String
        let username: String?

        init(session: DeviceSession) {
            name = session.serverName
            username = session.username
        }

        init(name: String, username: String?) {
            self.name = name
            self.username = username
        }
    }

    enum Destination: Equatable {
        case loading
        case connection(recoverableError: String?)
        case library(ServerSummary)
    }

    @Published private(set) var destination: Destination = .loading

    private let sessionUpdates: () async throws -> AsyncStream<DeviceSession?>
    let connectionService: ConnectionService
    let serverDiscovery: BonjourServerDiscovery
    private var observation: Task<Void, Never>?

    convenience init(sessionUpdates: @escaping () async throws -> AsyncStream<DeviceSession?>) {
        self.init(connectionService: ConnectionService(), serverDiscovery: BonjourServerDiscovery(), sessionUpdates: sessionUpdates)
    }

    init(connectionService: ConnectionService, serverDiscovery: BonjourServerDiscovery,
         sessionUpdates: @escaping () async throws -> AsyncStream<DeviceSession?>) {
        self.connectionService = connectionService
        self.serverDiscovery = serverDiscovery
        self.sessionUpdates = sessionUpdates
    }

    deinit {
        observation?.cancel()
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                let updates = try await sessionUpdates()
                for await session in updates {
                    guard !Task.isCancelled else { return }
                    destination = session.map { .library(ServerSummary(session: $0)) }
                        ?? .connection(recoverableError: nil)
                }
                guard !Task.isCancelled else { return }
                destination = .connection(recoverableError: "The saved connection could not be monitored. Try again.")
                observation = nil
            } catch {
                guard !Task.isCancelled else { return }
                destination = .connection(recoverableError: "The saved connection could not be read. Try again.")
                observation = nil
            }
        }
    }

    func retry() {
        observation?.cancel()
        observation = nil
        destination = .loading
        start()
    }
}
