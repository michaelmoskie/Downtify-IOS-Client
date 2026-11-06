import XCTest
@testable import Downtify

@MainActor
final class SessionPresentationCoordinatorTests: XCTestCase {
    func testRestoredSessionRoutesToLibraryWithoutPublishingCredentials() async throws {
        let session = makeSession()
        let coordinator = SessionPresentationCoordinator {
            let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
            continuation.yield(session)
            return updates
        }

        coordinator.start()
        await waitUntil { coordinator.destination == .library(.init(name: "Home", username: "listener")) }

        XCTAssertEqual(coordinator.destination, .library(.init(name: "Home", username: "listener")))
        if case let .library(summary) = coordinator.destination {
            XCTAssertFalse(String(describing: summary).contains(session.token))
        } else {
            XCTFail("Expected library route")
        }
    }

    func testSessionStoreReadErrorIsRecoverableAndCanRetry() async throws {
        var attempts = 0
        let coordinator = SessionPresentationCoordinator {
            attempts += 1
            if attempts == 1 { throw KeychainSessionError.invalidRecord }
            let (updates, continuation) = AsyncStream<DeviceSession?>.makeStream()
            continuation.yield(nil)
            return updates
        }

        coordinator.start()
        await waitUntil {
            if case .connection(recoverableError: .some) = coordinator.destination { return true }
            return false
        }
        if case .connection(let message) = coordinator.destination {
            XCTAssertNotNil(message)
        } else {
            XCTFail("Expected recoverable connection route")
        }

        coordinator.retry()
        await waitUntil { coordinator.destination == .connection(recoverableError: nil) }
        XCTAssertEqual(attempts, 2)
    }

    private func makeSession() -> DeviceSession {
        DeviceSession(baseAddress: "https://example.test", serverID: "server", serverName: "Home",
                      deviceID: "device", username: "listener", role: nil, token: "secret-token",
                      allowsInsecureHTTP: false)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1), condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}
