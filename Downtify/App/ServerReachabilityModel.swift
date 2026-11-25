import Combine
import Foundation
import Network

/// Whether the signed-in server answers right now. Home shows a banner while it does not.
@MainActor
final class ServerReachabilityModel: ObservableObject {
    @Published private(set) var isUnreachable = false

    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private let probe: @MainActor (DeviceSession) async -> Bool
    private let timeout: Duration
    private let retryInterval: Duration
    private let monitorsNetworkPath: Bool
    private var session: DeviceSession?
    private var active = false
    private var pathAvailable = true
    private var observation: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?

    init(sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>,
         probe: @escaping @MainActor (DeviceSession) async -> Bool,
         timeout: Duration = .seconds(10), retryInterval: Duration = .seconds(15),
         monitorsNetworkPath: Bool = true) {
        self.sessionUpdates = sessionUpdates
        self.probe = probe
        self.timeout = timeout
        self.retryInterval = retryInterval
        self.monitorsNetworkPath = monitorsNetworkPath
    }

    deinit {
        observation?.cancel()
        checkTask?.cancel()
        retryTask?.cancel()
        monitor?.cancel()
    }

    func start() {
        guard observation == nil else { return }
        if monitorsNetworkPath {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor in self?.setPathAvailable(available) }
            }
            monitor.start(queue: DispatchQueue(label: "app.downtify.server-reachability"))
        }
        let updates = sessionUpdates
        observation = Task { [weak self] in
            guard let stream = try? await updates() else { return }
            for await session in stream {
                guard !Task.isCancelled else { return }
                self?.changeSession(session)
            }
        }
    }

    /// Checks again when the app comes to the foreground; stops retrying in the background.
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active {
            check()
        } else {
            retryTask?.cancel()
            retryTask = nil
        }
    }

    /// Asks the server now, for example when the banner is tapped.
    func check() {
        retryTask?.cancel()
        retryTask = nil
        checkTask?.cancel()
        guard let session else {
            isUnreachable = false
            return
        }
        guard pathAvailable else {
            isUnreachable = true
            return
        }
        checkTask = Task { [weak self] in
            guard let self else { return }
            let reachable = await self.answers(session)
            guard !Task.isCancelled, self.session == session else { return }
            self.isUnreachable = !reachable
            if !reachable { self.scheduleRetry() }
        }
    }

    private func changeSession(_ session: DeviceSession?) {
        guard self.session != session else { return }
        self.session = session
        isUnreachable = false
        check()
    }

    private func setPathAvailable(_ available: Bool) {
        guard pathAvailable != available else { return }
        pathAvailable = available
        check()
    }

    private func scheduleRetry() {
        guard active else { return }
        let interval = retryInterval
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    /// The probe, or false if it takes longer than `timeout`.
    private func answers(_ session: DeviceSession) async -> Bool {
        let probe = probe
        let timeout = timeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await probe(session) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
