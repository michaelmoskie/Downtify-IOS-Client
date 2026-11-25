import XCTest
@testable import Downtify

@MainActor
final class ServerReachabilityModelTests: XCTestCase {
    private final class Server {
        var reachable = false
        var delay: Duration = .zero
        var probes = 0
    }

    func testUnreachableServerShowsBannerUntilACheckSucceeds() async throws {
        let server = Server()
        let (updates, sessions) = AsyncStream<DeviceSession?>.makeStream()
        let model = makeModel(server, updates: updates)
        model.start()
        model.setActive(true)
        XCTAssertFalse(model.isUnreachable)

        sessions.yield(session())
        try await waitUntil { model.isUnreachable }

        server.reachable = true
        model.check()
        try await waitUntil { !model.isUnreachable }
    }

    func testSlowServerCountsAsUnreachableAndSignOutClearsBanner() async throws {
        let server = Server()
        server.reachable = true
        server.delay = .seconds(30)
        let (updates, sessions) = AsyncStream<DeviceSession?>.makeStream()
        let model = makeModel(server, updates: updates)
        model.start()
        sessions.yield(session())
        try await waitUntil { model.isUnreachable }

        sessions.yield(nil)
        try await waitUntil { !model.isUnreachable }
    }

    func testRetriesWhileActiveButNotInBackground() async throws {
        let server = Server()
        let (updates, sessions) = AsyncStream<DeviceSession?>.makeStream()
        let model = makeModel(server, updates: updates)
        model.start()
        model.setActive(true)
        sessions.yield(session())
        try await waitUntil { server.probes >= 2 }
        XCTAssertTrue(model.isUnreachable)

        server.reachable = true
        try await waitUntil { !model.isUnreachable }
        server.reachable = false
        model.setActive(false)
        model.check()
        try await waitUntil { model.isUnreachable }
        let probes = server.probes
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(server.probes, probes)
    }

    private func makeModel(_ server: Server, updates: AsyncStream<DeviceSession?>) -> ServerReachabilityModel {
        ServerReachabilityModel(sessionUpdates: { updates }, probe: { _ in
            server.probes += 1
            if server.delay > .zero { try? await Task.sleep(for: server.delay) }
            return server.reachable
        }, timeout: .milliseconds(50), retryInterval: .milliseconds(20), monitorsNetworkPath: false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met")
    }

    private func session() -> DeviceSession {
        DeviceSession(baseAddress: "https://music.local", serverID: "server", serverName: "Music",
                      deviceID: "device", username: "user", role: nil, token: "test-token", allowsInsecureHTTP: false)
    }
}
