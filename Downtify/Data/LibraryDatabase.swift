import Foundation
import SQLite3

struct LibraryCheckpoint: Equatable, Sendable {
    let cursor: Int64
    let etag: String?
    let revision: Int64
}

enum LibraryDatabaseError: Error, Equatable {
    case storageUnavailable
    case sqlite(Int32)
    case unsupportedSchema(Int64)
    case invalidPage
    case invalidStoredData
    case checkpointChanged
}

/// A durable user intent. Credentials are deliberately never persisted here.
struct PendingCollectionAction: Codable, Equatable, Identifiable, Sendable {
    enum Target: Codable, Equatable, Sendable {
        case like(trackID: String)
        case favorite(name: String, owner: String?, manual: Bool?)
    }
    enum Status: String, Codable, Sendable { case queued, sent, failed }

    let id: UUID
    let target: Target
    let desiredValue: Bool
    var attempts: Int
    var nextAttempt: Date?
    var status: Status
    var failure: String?

    init(target: Target, desiredValue: Bool) {
        id = UUID()
        self.target = target
        self.desiredValue = desiredValue
        attempts = 0
        nextAttempt = nil
        status = .queued
        failure = nil
    }
}

/// Each library write and its checkpoint share the same SQLite transaction.
actor LibraryDatabase {
    private let fileURL: URL?
    private var connection: SQLiteConnection?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func browseData(_ key: String, in scope: LibraryScope) throws -> Data? {
        try database().withStatement("""
            SELECT payload FROM library_browse WHERE server_id = ? AND account = ? AND kind = ?
            """) { statement in
            try statement.bind(scope)
            try statement.bind(key, at: 3)
            return try statement.next() ? statement.payload() : nil
        }
    }

    func saveBrowseData(_ data: Data, key: String, in scope: LibraryScope) throws {
        try database().withStatement("""
            INSERT INTO library_browse (server_id, account, kind, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT (server_id, account, kind) DO UPDATE SET payload = excluded.payload
            """) { statement in
            try statement.bind(scope)
            try statement.bind(key, at: 3)
            try statement.bind(data, at: 4)
            try statement.execute()
        }
    }

    /// Actions are scoped to the pairing as well as the library account. Rows are
    /// ordered by SQLite's durable sequence, so opposite taps are never coalesced.
    func pendingActions(in scope: LibraryScope, deviceID: String) throws -> [PendingCollectionAction] {
        try database().withStatement("""
            SELECT payload FROM pending_collection_actions
            WHERE server_id = ? AND account = ? AND device_id = ? ORDER BY sequence
            """) { statement in
            try statement.bind(scope)
            try statement.bind(deviceID, at: 3)
            var actions: [PendingCollectionAction] = []
            while try statement.next() {
                guard let payload = statement.payload() else { throw LibraryDatabaseError.invalidStoredData }
                do { actions.append(try JSONDecoder().decode(PendingCollectionAction.self, from: payload)) }
                catch { throw LibraryDatabaseError.invalidStoredData }
            }
            return actions
        }
    }

    func appendPendingAction(_ action: PendingCollectionAction, in scope: LibraryScope, deviceID: String) throws {
        let payload = try JSONEncoder().encode(action)
        try database().withStatement("""
            INSERT INTO pending_collection_actions (server_id, account, device_id, action_id, payload)
            VALUES (?, ?, ?, ?, ?)
            """) { statement in
            try statement.bind(scope)
            try statement.bind(deviceID, at: 3)
            try statement.bind(action.id.uuidString, at: 4)
            try statement.bind(payload, at: 5)
            try statement.execute()
        }
    }

    func updatePendingAction(_ action: PendingCollectionAction, in scope: LibraryScope, deviceID: String) throws {
        let payload = try JSONEncoder().encode(action)
        try database().withStatement("""
            UPDATE pending_collection_actions SET payload = ?
            WHERE server_id = ? AND account = ? AND device_id = ? AND action_id = ?
            """) { statement in
            try statement.bind(payload, at: 1)
            try statement.bind(scope.serverID, at: 2)
            try statement.bind(scope.account, at: 3)
            try statement.bind(deviceID, at: 4)
            try statement.bind(action.id.uuidString, at: 5)
            try statement.execute()
        }
    }

    func removePendingAction(_ id: UUID, in scope: LibraryScope, deviceID: String) throws {
        try database().withStatement("""
            DELETE FROM pending_collection_actions
            WHERE server_id = ? AND account = ? AND device_id = ? AND action_id = ?
            """) { statement in
            try statement.bind(scope)
            try statement.bind(deviceID, at: 3)
            try statement.bind(id.uuidString, at: 4)
            try statement.execute()
        }
    }

    func removePendingActions(in scope: LibraryScope, deviceID: String) throws {
        try database().withStatement("""
            DELETE FROM pending_collection_actions WHERE server_id = ? AND account = ? AND device_id = ?
            """) { statement in
            try statement.bind(scope)
            try statement.bind(deviceID, at: 3)
            try statement.execute()
        }
    }

    func checkpoint(for scope: LibraryScope) throws -> LibraryCheckpoint? {
        try database().checkpoint(for: scope)
    }

    func snapshot(for scope: LibraryScope) throws -> LibrarySnapshot {
        let db = try database()
        return try db.transaction("BEGIN") {
            let cursor = try db.checkpoint(for: scope)?.cursor
            let tracks = try db.withStatement("""
                SELECT payload FROM library_tracks WHERE server_id = ? AND account = ? ORDER BY track_id
                """) { statement in
                try statement.bind(scope)
                var tracks: [LibraryTrack] = []
                while try statement.next() {
                    try Task.checkCancellation()
                    tracks.append(try statement.track())
                }
                return tracks
            }
            return LibrarySnapshot(cursor: cursor, tracks: tracks)
        }
    }

    func track(id: String, in scope: LibraryScope) throws -> LibraryTrack? {
        try database().withStatement("""
            SELECT payload FROM library_tracks WHERE server_id = ? AND account = ? AND track_id = ?
            """) { statement in
            try statement.bind(scope)
            try statement.bind(id, at: 3)
            return try statement.next() ? statement.track() : nil
        }
    }

    func apply(
        _ page: LibraryPage, etag: String?, in scope: LibraryScope, expected checkpoint: LibraryCheckpoint?
    ) throws {
        let db = try database()
        try db.transaction("BEGIN IMMEDIATE") {
            try Task.checkCancellation()
            guard try db.checkpoint(for: scope) == checkpoint else { throw LibraryDatabaseError.checkpointChanged }
            let since = checkpoint?.cursor ?? 0
            guard page.cursor >= 0, page.full || (since > 0 && page.cursor >= since) else {
                throw LibraryDatabaseError.invalidPage
            }

            if page.full {
                try db.withStatement("DELETE FROM library_tracks WHERE server_id = ? AND account = ?") {
                    try $0.bind(scope)
                    try $0.execute()
                }
            }

            try db.withStatement("""
                INSERT INTO library_tracks (server_id, account, track_id, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT (server_id, account, track_id) DO UPDATE SET payload = excluded.payload
                """) { statement in
                let encoder = JSONEncoder()
                for track in page.tracks {
                    try Task.checkCancellation()
                    guard !track.id.isEmpty else { throw LibraryDatabaseError.invalidPage }
                    try statement.bind(scope)
                    try statement.bind(track.id, at: 3)
                    try statement.bind(encoder.encode(track), at: 4)
                    try statement.execute()
                }
            }

            if !page.full {
                try db.withStatement("""
                    DELETE FROM library_tracks WHERE server_id = ? AND account = ? AND track_id = ?
                    """) { statement in
                    for id in page.deleted {
                        try Task.checkCancellation()
                        guard !id.isEmpty else { throw LibraryDatabaseError.invalidPage }
                        try statement.bind(scope)
                        try statement.bind(id, at: 3)
                        try statement.execute()
                    }
                }
            }

            // Validators belong to the exact since query that produced them.
            let nextETag = page.cursor == since ? etag : nil
            try db.withStatement("""
                INSERT INTO library_checkpoints (server_id, account, cursor, etag, revision) VALUES (?, ?, ?, ?, 1)
                ON CONFLICT (server_id, account) DO UPDATE SET
                    cursor = excluded.cursor, etag = excluded.etag, revision = revision + 1
                """) { statement in
                try statement.bind(scope)
                try statement.bind(page.cursor, at: 3)
                try statement.bind(nextETag, at: 4)
                try statement.execute()
            }
            try Task.checkCancellation()
        }
    }

    private func database() throws -> SQLiteConnection {
        if let connection { return connection }

        let url: URL
        do {
            url = try fileURL ?? Self.storageURL()
        } catch {
            throw LibraryDatabaseError.storageUnavailable
        }
        let opened = try SQLiteConnection(url: url)
        if fileURL == nil {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                throw LibraryDatabaseError.storageUnavailable
            }
        }
        try opened.migrate()
        connection = opened
        return opened
    }

    private static func storageURL() throws -> URL {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        var directory = support.appending(path: "DowntifyLibrary", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        return directory.appending(path: "library.sqlite")
    }
}

private final class SQLiteConnection {
    private let handle: OpaquePointer
    private static let migrations = [
        """
        CREATE TABLE library_tracks (
            server_id TEXT NOT NULL,
            account TEXT NOT NULL,
            track_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (server_id, account, track_id)
        ) WITHOUT ROWID;
        CREATE TABLE library_checkpoints (
            server_id TEXT NOT NULL,
            account TEXT NOT NULL,
            cursor INTEGER NOT NULL CHECK (cursor >= 0),
            revision INTEGER NOT NULL CHECK (revision > 0),
            PRIMARY KEY (server_id, account)
        ) WITHOUT ROWID;
        """,
        "ALTER TABLE library_checkpoints ADD COLUMN etag TEXT;",
        """
        CREATE TABLE library_browse (
            server_id TEXT NOT NULL,
            account TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (server_id, account, kind)
        ) WITHOUT ROWID;
        """,
        """
        CREATE TABLE pending_collection_actions (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            server_id TEXT NOT NULL,
            account TEXT NOT NULL,
            device_id TEXT NOT NULL,
            action_id TEXT NOT NULL UNIQUE,
            payload BLOB NOT NULL
        );
        CREATE INDEX pending_collection_actions_scope
            ON pending_collection_actions(server_id, account, device_id, sequence);
        """
    ]

    init(url: URL) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw LibraryDatabaseError.sqlite(result)
        }
        handle = connection
        try check(sqlite3_busy_timeout(handle, 1_000))
    }

    deinit { sqlite3_close(handle) }

    func migrate() throws {
        try transaction("BEGIN IMMEDIATE") {
            let version = try withStatement("PRAGMA user_version") {
                guard try $0.next() else { throw LibraryDatabaseError.invalidStoredData }
                return $0.integer(at: 0)
            }
            guard version >= 0, version <= Self.migrations.count else {
                throw LibraryDatabaseError.unsupportedSchema(version)
            }

            for (index, migration) in Self.migrations.enumerated().dropFirst(Int(version)) {
                try execute(migration)
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    func checkpoint(for scope: LibraryScope) throws -> LibraryCheckpoint? {
        try withStatement("""
            SELECT cursor, etag, revision FROM library_checkpoints WHERE server_id = ? AND account = ?
            """) { statement in
            try statement.bind(scope)
            guard try statement.next() else { return nil }
            return LibraryCheckpoint(cursor: statement.integer(at: 0), etag: statement.text(at: 1),
                                     revision: statement.integer(at: 2))
        }
    }

    func withStatement<Value>(_ sql: String, _ body: (SQLiteStatement) throws -> Value) throws -> Value {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw LibraryDatabaseError.invalidStoredData }
        defer { sqlite3_finalize(statement) }
        return try body(SQLiteStatement(handle: statement))
    }

    func transaction<Value>(_ begin: String, _ body: () throws -> Value) throws -> Value {
        try execute(begin)
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }
}

private struct SQLiteStatement {
    let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ scope: LibraryScope) throws {
        try bind(scope.serverID, at: 1)
        try bind(scope.account, at: 2)
    }

    func bind(_ value: String?, at index: Int32) throws {
        guard let value else { return try check(sqlite3_bind_null(handle, index)) }
        try value.withCString {
            try check(sqlite3_bind_text(handle, index, $0, Int32(value.utf8.count), Self.transient))
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    func bind(_ data: Data, at index: Int32) throws {
        try data.withUnsafeBytes {
            try check(sqlite3_bind_blob64(handle, index, $0.baseAddress, UInt64($0.count), Self.transient))
        }
    }

    func next() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let code: throw LibraryDatabaseError.sqlite(code)
        }
    }

    func execute() throws {
        guard try !next() else { throw LibraryDatabaseError.invalidStoredData }
        try check(sqlite3_reset(handle))
    }

    func integer(at index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }

    func text(at index: Int32) -> String? {
        sqlite3_column_text(handle, index).map { String(cString: $0) }
    }

    func payload() -> Data? {
        sqlite3_column_blob(handle, 0).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(handle, 0))) }
    }

    func track() throws -> LibraryTrack {
        guard let data = payload() else { throw LibraryDatabaseError.invalidStoredData }
        do {
            return try JSONDecoder().decode(LibraryTrack.self, from: data)
        } catch {
            throw LibraryDatabaseError.invalidStoredData
        }
    }
}

private func check(_ result: Int32) throws {
    guard result == SQLITE_OK else { throw LibraryDatabaseError.sqlite(result) }
}
