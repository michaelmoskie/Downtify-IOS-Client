import Foundation

enum LibrarySyncResult: Equatable {
    case unchanged
    case replaced(trackCount: Int)
    case applied(changed: Int, deleted: Int)
}

enum LibrarySyncError: Error, Equatable {
    case signedOut
    case sessionChanged
}

struct LibraryRepository {
    private let database: LibraryDatabase
    private let feed: any LibraryFeedFetching
    private let sessionProvider: @Sendable () async throws -> DeviceSession?
    private let wait: @Sendable (Duration) async throws -> Void

    init(
        database: LibraryDatabase,
        feed: any LibraryFeedFetching,
        session: @escaping @Sendable () async throws -> DeviceSession?,
        wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.database = database
        self.feed = feed
        sessionProvider = session
        self.wait = wait
    }

    func snapshot() async throws -> LibrarySnapshot {
        let session = try await activeSession()
        return try await snapshot(for: session)
    }

    func snapshot(for session: DeviceSession) async throws -> LibrarySnapshot {
        let result = try await database.snapshot(for: scope(for: session))
        try await requireCurrent(session)
        return result
    }

    func track(id: String) async throws -> LibraryTrack? {
        let session = try await activeSession()
        let result = try await database.track(id: id, in: scope(for: session))
        try await requireCurrent(session)
        return result
    }

    func sync(refresh: Bool = false) async throws -> LibrarySyncResult {
        try await sync(for: activeSession(), refresh: refresh)
    }

    func sync(for session: DeviceSession, refresh: Bool = false) async throws -> LibrarySyncResult {
        let scope = scope(for: session)
        for attempt in 0..<3 {
            try await requireCurrent(session)
            let checkpoint = try await database.checkpoint(for: scope)
            let result = try await fetch(checkpoint, refresh: refresh, session: session)
            try await requireCurrent(session)
            switch result {
            case .unchanged:
                return .unchanged
            case let .page(page, etag):
                if !page.full, page.cursor == checkpoint?.cursor, page.tracks.isEmpty, page.deleted.isEmpty,
                   etag == checkpoint?.etag {
                    return .unchanged
                }
                do {
                    try await database.apply(page, etag: etag, in: scope, expected: checkpoint)
                } catch LibraryDatabaseError.checkpointChanged where attempt < 2 {
                    // Another refresh committed while this one was fetching. Fetch again from its checkpoint.
                    continue
                }
                if page.full { return .replaced(trackCount: page.tracks.count) }
                if page.tracks.isEmpty, page.deleted.isEmpty, page.cursor == checkpoint?.cursor {
                    return .unchanged
                }
                return .applied(changed: page.tracks.count, deleted: page.deleted.count)
            }
        }
        throw LibraryDatabaseError.checkpointChanged
    }

    func requireCurrent(_ session: DeviceSession) async throws {
        try Task.checkCancellation()
        guard try await sessionProvider() == session else { throw LibrarySyncError.sessionChanged }
        try Task.checkCancellation()
    }

    private func activeSession() async throws -> DeviceSession {
        guard let session = try await sessionProvider() else { throw LibrarySyncError.signedOut }
        return session
    }

    private func scope(for session: DeviceSession) -> LibraryScope {
        LibraryScope(serverID: session.serverID, username: session.username, deviceID: session.deviceID)
    }

    private func fetch(
        _ checkpoint: LibraryCheckpoint?, refresh: Bool, session: DeviceSession
    ) async throws -> LibraryFeedResult {
        for attempt in 0..<3 {
            try await requireCurrent(session)
            do {
                return try await feed.fetch(since: checkpoint?.cursor ?? 0, etag: refresh ? nil : checkpoint?.etag,
                                            refresh: refresh, session: session)
            } catch {
                guard attempt < 2, let delay = retryDelay(for: error, attempt: attempt) else { throw error }
                try await wait(delay)
            }
        }
        throw APIError.transportFailure
    }

    private func retryDelay(for error: Error, attempt: Int) -> Duration? {
        let fallback = Duration.milliseconds(250 * (1 << attempt))
        switch error {
        case APIError.transportFailure:
            return fallback
        case APIError.httpStatus(let status, let retryAfter) where [408, 429, 500, 502, 503, 504].contains(status):
            if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
                // Leave a longer server cooldown to the caller instead of retrying before it expires.
                return retryAfter <= 120 ? .seconds(retryAfter) : nil
            }
            return status == 429 ? .seconds(60) : fallback
        default:
            return nil
        }
    }
}
