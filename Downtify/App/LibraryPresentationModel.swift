import Combine
import Foundation

enum LibraryTrackOrdering {
    static func sorted(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        tracks.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    static func matching(_ tracks: [LibraryTrack], query: String) -> [LibraryTrack] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) ||
                $0.album.localizedStandardContains(query)
        }
    }
}

@MainActor
final class LibraryPresentationModel: ObservableObject {
    enum State: Equatable {
        case loading
        case empty
        case ready
        case refreshing
        case cachedError(String)
        case storageFailure(String)
    }

    @Published private(set) var tracks: [LibraryTrack] = []
    @Published private(set) var state: State = .loading

    private let repository: LibraryRepository
    private let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?>
    private var observation: Task<Void, Never>?
    private var session: DeviceSession?
    private var generation = 0

    init(repository: LibraryRepository, sessionUpdates: @escaping @Sendable () async throws -> AsyncStream<DeviceSession?>) {
        self.repository = repository
        self.sessionUpdates = sessionUpdates
    }

    deinit { observation?.cancel() }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                for await session in try await sessionUpdates() {
                    guard !Task.isCancelled else { return }
                    await changeSession(to: session)
                }
            } catch {
                state = .storageFailure("The saved library could not be loaded.")
            }
        }
    }

    func refresh() async {
        guard let session else { return }
        let request = generation
        state = tracks.isEmpty ? .loading : .refreshing
        do {
            _ = try await repository.sync(for: session, refresh: true)
            guard request == generation, self.session == session else { return }
            await loadSnapshot(for: session, generation: request, clearRefreshError: true)
        } catch LibrarySyncError.sessionChanged {
            return
        } catch {
            guard request == generation, self.session == session else { return }
            if case .storageFailure = state { return }
            state = tracks.isEmpty
                ? .cachedError("Library refresh failed. Pull to try again.")
                : .cachedError("Showing saved music. Refresh failed.")
        }
    }

    func syncDidUpdate(for session: DeviceSession) async {
        guard self.session == session else { return }
        await loadSnapshot(for: session, generation: generation, clearRefreshError: true)
    }

    func syncDidFail(for session: DeviceSession, message: String) {
        guard self.session == session else { return }
        if case .storageFailure = state { return }
        state = .cachedError(message)
    }

    private func changeSession(to newSession: DeviceSession?) async {
        generation += 1
        let request = generation
        session = newSession
        tracks = []
        guard let newSession else { state = .empty; return }
        state = .loading
        await loadSnapshot(for: newSession, generation: request)
    }

    private func loadSnapshot(
        for session: DeviceSession, generation request: Int, clearRefreshError: Bool = false
    ) async {
        do {
            let snapshot = try await repository.snapshot(for: session)
            guard request == generation, self.session == session else { return }
            tracks = snapshot.tracks
            if !clearRefreshError, case .cachedError = state { return }
            state = snapshot.tracks.isEmpty ? .empty : .ready
        } catch LibrarySyncError.sessionChanged {
            return
        } catch {
            guard request == generation, self.session == session else { return }
            state = .storageFailure("Saved library storage is unavailable.")
        }
    }
}
