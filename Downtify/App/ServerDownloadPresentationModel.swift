import Combine
import Foundation

enum ServerDownloadActionState: Equatable, Sendable {
    case idle
    case submitting
    case queued(jobID: String?)
    case accepted
    case partiallyAccepted(successful: Int, expected: Int)
    case outcomeUnknown
    case failed(String)
}

@MainActor
final class ServerDownloadPresentationModel: ObservableObject {
    @Published private(set) var session: DeviceSession?
    @Published private(set) var jobs: [ServerDownloadQueue.Job] = []
    @Published private(set) var queueStatus: ServerDownloadQueue.Status?
    @Published private(set) var queueError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var actionStates: [String: ServerDownloadActionState] = [:]

    private let queue: ServerDownloadQueue
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private var observation: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var queueEventRefresh: Task<Void, Never>?
    private var sessionGeneration = 0

    init(
        queue: ServerDownloadQueue,
        sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>
    ) {
        self.queue = queue
        self.sessionUpdates = sessionUpdates
    }

    deinit {
        observation?.cancel()
        polling?.cancel()
        refreshTask?.cancel()
        queueEventRefresh?.cancel()
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                for await next in try await sessionUpdates() {
                    guard !Task.isCancelled else { return }
                    setSession(next)
                }
            } catch {
                queueError = "Could not check the current server session."
            }
        }
    }

    func actionState(for song: CatalogSong) -> ServerDownloadActionState {
        actionStates[song.id.description] ?? .idle
    }

    func request(song: CatalogSong) async {
        let key = song.id.description
        guard beginAction(key: key), let active = session else { return }
        do {
            let jobID = try await queue.requestTrack(song: song, session: active)
            guard isCurrent(active) else { return }
            actionStates[key] = .queued(jobID: jobID)
            await refreshQueue()
        } catch is CancellationError {
            guard isCurrent(active) else { return }
            actionStates[key] = .outcomeUnknown
        } catch {
            guard isCurrent(active) else { return }
            actionStates[key] = actionFailure(for: error)
        }
    }

    func requestBatch(songs: [CatalogSong], options: ServerDownloadQueue.BatchOptions = .init()) async {
        guard !songs.isEmpty, let active = session else { return }
        var seen = Set<String>()
        let keys = songs.map { $0.id.description }.filter { seen.insert($0).inserted }
        guard keys.allSatisfy({ canBeginAction($0) }) else { return }
        keys.forEach { actionStates[$0] = .submitting }
        do {
            let response = try await queue.requestBatch(songs: songs, options: options, session: active)
            guard isCurrent(active) else { return }
            let jobIDs = response.jobIDs
            for (index, key) in keys.enumerated() {
                actionStates[key] = .queued(jobID: jobIDs.indices.contains(index) ? jobIDs[index] : nil)
            }
            await refreshQueue()
        } catch is CancellationError {
            guard isCurrent(active) else { return }
            keys.forEach { actionStates[$0] = .outcomeUnknown }
        } catch {
            guard isCurrent(active) else { return }
            let failure = actionFailure(for: error)
            keys.forEach { actionStates[$0] = failure }
        }
    }

    func requestAlbum(url: String, expected: [CatalogSong]? = nil) async {
        let key = "album:\(url)"
        guard beginAction(key: key), let active = session else { return }
        do {
            let response = try await queue.requestAlbum(url: url, session: active)
            guard isCurrent(active) else { return }
            actionStates[key] = .accepted
            if let expected {
                let jobsByProviderID = response
                var successful = 0
                for song in expected {
                    let providerIDs = [song.youtubeID, song.songID, song.url].compactMap { $0 }
                    if providerIDs.contains(where: { jobsByProviderID[$0] != nil }) {
                        actionStates[song.id.description] = .accepted
                        successful += 1
                    } else {
                        actionStates[song.id.description] = .failed("This album track was not queued.")
                    }
                }
                if successful < expected.count {
                    actionStates[key] = .partiallyAccepted(successful: successful, expected: expected.count)
                }
            }
            await refreshQueue()
        } catch is CancellationError {
            guard isCurrent(active) else { return }
            actionStates[key] = .outcomeUnknown
        } catch {
            guard isCurrent(active) else { return }
            actionStates[key] = actionFailure(for: error)
        }
    }

    func actionState(forAlbumURL url: String) -> ServerDownloadActionState {
        actionStates["album:\(url)"] ?? .idle
    }

    /// Called for `queue_reload` and job progress events. Progress frames only refresh the
    /// server queue and never trigger a library resync.
    func queueDidChange() async {
        guard queueEventRefresh == nil else { return }
        queueEventRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            await refreshQueue()
            queueEventRefresh = nil
        }
    }

    func refreshQueue() async {
        guard let active = session else {
            jobs = []
            queueStatus = nil
            queueError = "Reconnect to view the server queue."
            return
        }
        if let refreshTask {
            await refreshTask.value
            return
        }

        let generation = sessionGeneration
        let id = UUID()
        isRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == sessionGeneration { isRefreshing = false } }
            do {
                async let fetchedJobs = queue.jobs(session: active)
                async let fetchedStatus = queue.status(session: active)
                let values = try await (fetchedJobs, fetchedStatus)
                guard isCurrent(active), generation == sessionGeneration else { return }
                jobs = values.0
                queueStatus = values.1
                queueError = nil
                updatePolling(for: active)
                reconcileActions(with: values.0)
            } catch {
                guard isCurrent(active), generation == sessionGeneration else { return }
                queueError = message(for: error)
            }
        }
        refreshID = id
        refreshTask = task
        await task.value
        if refreshID == id {
            refreshTask = nil
            refreshID = nil
        }
    }

    private func beginAction(key: String) -> Bool {
        guard session != nil, canBeginAction(key) else { return false }
        actionStates[key] = .submitting
        return true
    }

    private func canBeginAction(_ key: String) -> Bool {
        switch actionStates[key] ?? .idle {
        case .submitting, .queued, .accepted, .partiallyAccepted, .outcomeUnknown: false
        case .idle, .failed: true
        }
    }

    private func setSession(_ newSession: DeviceSession?) {
        guard session != newSession else { return }
        sessionGeneration += 1
        refreshTask?.cancel()
        queueEventRefresh?.cancel()
        queueEventRefresh = nil
        refreshTask = nil
        isRefreshing = false
        polling?.cancel()
        polling = nil
        session = newSession
        jobs = []
        queueStatus = nil
        queueError = nil
        actionStates = [:]
        guard newSession != nil else { return }
        Task { await refreshQueue() }
    }

    private func isCurrent(_ expected: DeviceSession) -> Bool {
        session == expected
    }

    private func updatePolling(for active: DeviceSession) {
        let hasActiveJobs = (queueStatus?.active ?? 0) > 0 || jobs.contains { job in
            ["queued", "pending", "running", "downloading", "processing"].contains(job.status.lowercased())
        }
        guard hasActiveJobs else {
            polling?.cancel()
            polling = nil
            return
        }
        guard polling == nil else { return }
        let generation = sessionGeneration
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, isCurrent(active), generation == sessionGeneration else { return }
                await refreshQueue()
            }
        }
    }

    private func reconcileActions(with jobs: [ServerDownloadQueue.Job]) {
        for key in Array(actionStates.keys) {
            guard actionStates[key] != .submitting else { continue }
            let matches = jobs.filter { job in
                guard let id = job.song.id else { return false }
                return key == "library:\(id)" || key.hasSuffix(":\(id)")
            }
            if let state = Self.reconciledState(for: matches) { actionStates[key] = state }
        }
    }

    static func reconciledState(for jobs: [ServerDownloadQueue.Job]) -> ServerDownloadActionState? {
        guard !jobs.isEmpty else { return nil }
        let active = ["queued", "pending", "running", "downloading", "processing"]
        if let job = jobs.first(where: { active.contains($0.status.lowercased()) }) {
            return .queued(jobID: job.id)
        }
        if jobs.contains(where: { ["done", "completed", "complete", "success", "succeeded"].contains($0.status.lowercased()) }) {
            return .accepted
        }
        if let job = jobs.first(where: { ["failed", "error", "cancelled", "canceled"].contains($0.status.lowercased()) }) {
            return .failed(job.message.flatMap { $0.isEmpty ? nil : $0 } ?? "The server download failed.")
        }
        return .outcomeUnknown
    }

    private func message(for error: Error) -> String {
        if case APIError.httpStatus(let status, _) = error {
            return "The server could not complete this request (\(status))."
        }
        if let apiError = error as? APIError, apiError == .insecureTransportConsentRequired {
            return "Allow HTTP for this server before requesting a download."
        }
        if let catalogError = error as? CatalogAPIError, catalogError == .libraryOnly {
            return "Server downloads are unavailable in library-only mode."
        }
        return "Could not complete the server download request."
    }

    private func actionFailure(for error: Error) -> ServerDownloadActionState {
        if let apiError = error as? APIError, apiError == .transportFailure {
            // A transport timeout can happen after the server accepted the POST. Keep the
            // action locked until the user checks the queue instead of encouraging a duplicate.
            return .outcomeUnknown
        }
        return .failed(message(for: error))
    }
}
