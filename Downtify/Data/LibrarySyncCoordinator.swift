import Foundation
import Combine

@MainActor
final class LibrarySyncCoordinator {
    enum Status: Equatable { case idle, syncing, failed(String) }
    @Published private(set) var status: Status = .idle
    @Published private(set) var updateGeneration = 0
    private let repository: LibraryRepository
    private let events: any LibraryEventStreaming
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private let verifySession: @Sendable (DeviceSession) async throws -> DeviceSessionStatus
    private let wait: @Sendable (Duration) async throws -> Void
    private let didUpdate: @MainActor (DeviceSession) async -> Void
    private let didFail: @MainActor (DeviceSession, String) async -> Void
    private var isForeground = false
    private var foregroundTask: Task<Void, Never>?

    init(
        repository: LibraryRepository, events: any LibraryEventStreaming,
        sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>,
        verifySession: @escaping @Sendable (DeviceSession) async throws -> DeviceSessionStatus,
        didUpdate: @escaping @MainActor (DeviceSession) async -> Void = { _ in },
        didFail: @escaping @MainActor (DeviceSession, String) async -> Void = { _, _ in },
        wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.events = events
        self.sessionUpdates = sessionUpdates
        self.verifySession = verifySession
        self.didUpdate = didUpdate
        self.didFail = didFail
        self.wait = wait
    }

    func setActive(_ active: Bool) {
        guard active != isForeground else { return }
        isForeground = active
        let previous = foregroundTask
        if active {
            foregroundTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                await self?.runWhileActive()
            }
        } else {
            previous?.cancel()
        }
    }

    func runWhileActive() async {
        guard let updates = try? await sessionUpdates() else { return }
        var current: DeviceSession?
        var sessionTask: Task<Void, Never>?
        for await session in updates {
            guard !Task.isCancelled else { break }
            guard current != session else { continue }
            sessionTask?.cancel()
            await sessionTask?.value
            guard !Task.isCancelled else { break }
            current = session
            if let session {
                sessionTask = Task { await self.run(for: session) }
            } else {
                sessionTask = nil
            }
        }
        sessionTask?.cancel()
        await sessionTask?.value
    }

    private func run(for session: DeviceSession) async {
        await sync(session)
        var failures = 0
        while !Task.isCancelled {
            var connected = false
            do {
                try await repository.requireCurrent(session)
                for try await event in try await events.events(for: session) {
                    try Task.checkCancellation()
                    if event == .connected {
                        connected = true
                        failures = 0
                    }
                    // A successful reconnect closes the gap in events while the app was offline.
                    await sync(session)
                }
            } catch is CancellationError {
                return
            } catch LibrarySyncError.sessionChanged {
                return
            } catch LibrarySocketError.refused {
                await verifyIfCurrent(session)
            } catch LibrarySocketError.disconnected where !connected {
                // Some failed handshakes do not expose their HTTP status through URLSession.
                await verifyIfCurrent(session)
            } catch APIError.httpStatus(401, _) {
                await verifyIfCurrent(session)
            } catch {
                // The next connection attempt will fetch from the last committed checkpoint.
            }

            do {
                try await repository.requireCurrent(session)
                try await wait(.seconds(min(120, 2 << failures)))
            } catch {
                return
            }
            failures = min(failures + 1, 6)
        }
    }

    private func sync(_ session: DeviceSession) async {
        status = .syncing
        do {
            _ = try await repository.sync(for: session)
            guard (try? await repository.requireCurrent(session)) != nil else { return }
            await didUpdate(session)
            updateGeneration += 1
            status = .idle
        } catch APIError.httpStatus(401, _) {
            status = .failed("The saved session was rejected.")
            await didFail(session, "The saved session was rejected. Showing saved music.")
            await verifyIfCurrent(session)
        } catch {
            status = .failed("Library refresh failed. Showing saved music.")
            await didFail(session, "Library refresh failed. Showing saved music.")
        }
    }

    private func verifyIfCurrent(_ session: DeviceSession) async {
        guard (try? await repository.requireCurrent(session)) != nil else { return }
        _ = try? await verifySession(session)
    }
}
