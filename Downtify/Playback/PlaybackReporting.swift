import CryptoKit
import Foundation

struct PlaybackListen: Codable, Equatable {
    let trackID: String
    let playID: UUID
    let playedAt: Date

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case playID = "play_id"
        case playedAt = "played_at"
    }
}

struct PlaybackListenProgress: Codable, Equatable {
    let id: UUID
    let started: Date
    var elapsed: TimeInterval = 0
    var enqueued = false

    init(id: UUID = UUID(), started: Date = Date()) {
        self.id = id
        self.started = started
    }

    mutating func add(_ delta: TimeInterval) {
        if delta > 0, delta <= 2 { elapsed += delta }
    }

    func qualifies(duration: TimeInterval?) -> Bool {
        elapsed >= min((duration ?? 480) / 2, 240)
    }
}

struct PlaybackActivity: Encodable {
    enum State: String, Encodable { case playing, paused, stopped }

    struct Track: Encodable {
        let trackID: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case trackID = "track_id"
            case title, artist, album, duration
        }
    }

    let player: UUID
    let state: State
    let track: Track?
    let position: TimeInterval
}

struct PlaybackReportAPI {
    var transport: any HTTPDataLoading = ConnectionHTTPTransport()

    func verifiedClient(for session: DeviceSession) async throws -> (APIClient, ServerAddress) {
        let address = try ServerAddress(session.baseAddress)
        guard !address.usesInsecureHTTP || session.allowsInsecureHTTP else { throw PlaybackFailure.insecureAddress }
        let client = APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
        let server = try await client.serverInfo(at: address)
        try Task.checkCancellation()
        guard server.serverID == session.serverID else { throw PlaybackFailure.differentServer }
        return (client, address)
    }

    func post(_ body: some Encodable, path: String, session: DeviceSession) async throws {
        let (client, address) = try await verifiedClient(for: session)
        var request = URLRequest(url: address.url(for: path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        _ = try await client.send(request, to: address)
    }
}

struct PlaybackListenOutbox {
    let root: URL

    static func applicationSupport() -> Self {
        let root = URL.applicationSupportDirectory.appending(path: "PlaybackListens", directoryHint: .isDirectory)
        return Self(root: root)
    }

    func insert(_ report: PlaybackListen, for scope: LibraryScope) throws {
        let folder = directory(for: scope)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var root = root
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try root.setResourceValues(resources)
        let file = folder.appending(path: report.playID.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(report).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func pending(for scope: LibraryScope) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory(for: scope), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    func report(at file: URL) throws -> PlaybackListen {
        try JSONDecoder().decode(PlaybackListen.self, from: Data(contentsOf: file))
    }

    func acknowledge(_ file: URL) throws {
        try FileManager.default.removeItem(at: file)
    }

    private func directory(for scope: LibraryScope) -> URL {
        let key = "\(scope.serverID.utf8.count):\(scope.serverID)\(scope.account)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: digest, directoryHint: .isDirectory)
    }
}

@MainActor
final class PlaybackReporting {
    private let outbox: PlaybackListenOutbox
    private let api: PlaybackReportAPI
    private let player: UUID
    private let verifySession: (DeviceSession) async -> Void
    private var session: DeviceSession?
    private var online = false
    private var listenTask: Task<Void, Never>?
    private var listenRetry: Task<Void, Never>?
    private var retryDelay: TimeInterval = 1
    private var activityTask: Task<Void, Never>?
    private var pendingActivity: PlaybackActivity?
    private var endingActivity: (session: DeviceSession, snapshot: PlaybackActivity)?
    private var lastActivity: PlaybackActivity?
    private var lastActivityTime: TimeInterval = 0

    init(outbox: PlaybackListenOutbox = .applicationSupport(), api: PlaybackReportAPI = PlaybackReportAPI(),
         defaults: UserDefaults = .standard, verifySession: @escaping (DeviceSession) async -> Void = { _ in }) {
        self.verifySession = verifySession
        self.outbox = outbox
        self.api = api
        let key = "playback.installID"
        player = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(player.uuidString, forKey: key)
    }

    deinit {
        listenTask?.cancel()
        listenRetry?.cancel()
        activityTask?.cancel()
    }

    func update(session: DeviceSession?, online: Bool) {
        guard self.session != session || self.online != online else { return }
        let sessionChanged = self.session != session
        if sessionChanged, self.online, online, let previous = self.session,
           let lastActivity, lastActivity.state != .stopped || pendingActivity?.state == .stopped {
            let stop = PlaybackActivity(player: player, state: .stopped, track: nil, position: 0)
            endingActivity = (previous, stop)
        }
        self.session = session
        self.online = online
        pendingActivity = nil
        if sessionChanged { lastActivity = nil }
        if !online {
            endingActivity = nil
            activityTask?.cancel()
        }
        lastActivityTime = -.infinity
        listenRetry?.cancel()
        listenRetry = nil
        retryDelay = 1
        // Keep the in-flight send serialized across session changes until its transport returns.
        listenTask?.cancel()
        flush()
        sendActivity()
    }

    func enqueue(_ report: PlaybackListen, for scope: LibraryScope) throws {
        try outbox.insert(report, for: scope)
        flush()
    }

    func publish(state: PlaybackActivity.State, track: LibraryTrack?, duration: TimeInterval?, position: TimeInterval) {
        guard online, session != nil else { return }
        let changed = lastActivity?.state != state || lastActivity?.track?.trackID != track?.id
        let now = ProcessInfo.processInfo.systemUptime
        if lastActivity == nil, state != .playing { return }
        if state == .paused, lastActivity?.track?.trackID != track?.id { return }
        guard changed || lastActivityTime == -.infinity
                || (state == .playing && now - lastActivityTime >= 30) else { return }
        let snapshot = PlaybackActivity(player: player, state: state, track: track.map {
            .init(trackID: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: duration)
        }, position: position)
        lastActivity = snapshot
        lastActivityTime = now
        pendingActivity = snapshot
        sendActivity()
    }

    private func flush() {
        guard listenTask == nil, listenRetry == nil, online, let session else { return }
        let scope = LibraryScope(serverID: session.serverID, username: session.username, deviceID: session.deviceID)
        listenTask = Task { [weak self] in
            guard let self else { return }
            var retry: TimeInterval?
            var acknowledged = false
            defer {
                listenTask = nil
                if Task.isCancelled {
                    flush()
                } else if let retry {
                    scheduleRetry(after: retry)
                } else if acknowledged {
                    retryDelay = 1
                    flush()
                }
            }
            do {
                for file in try outbox.pending(for: scope) {
                    try Task.checkCancellation()
                    guard let report = try? outbox.report(at: file) else { continue }
                    do {
                        try await api.post(report, path: "/api/discover/listens", session: session)
                        try outbox.acknowledge(file)
                        acknowledged = true
                    } catch is CancellationError {
                        return
                    } catch APIError.httpStatus(let status, let after) {
                        if status == 429 || status >= 500 {
                            let serverDelay = after.flatMap { $0.isFinite ? min(86_400, $0) : nil } ?? 0
                            retry = max(retryDelay, serverDelay)
                            return
                        }
                        // Retain rejected rows for recovery, while allowing other listens to upload.
                        retry = max(retry ?? 0, 300)
                        if status == 401 {
                            if !Task.isCancelled { await verifySession(session) }
                            return
                        }
                    } catch {
                        retry = retryDelay
                        return
                    }
                }
            } catch {
                retry = retryDelay
            }
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryDelay = min(300, retryDelay * 2)
        listenRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.listenRetry = nil
            self?.flush()
        }
    }

    private func sendActivity() {
        guard activityTask == nil, online else { return }
        let session: DeviceSession
        let snapshot: PlaybackActivity
        if let endingActivity {
            (session, snapshot) = endingActivity
            self.endingActivity = nil
        } else {
            guard let current = self.session, let pendingActivity else { return }
            session = current
            snapshot = pendingActivity
            self.pendingActivity = nil
        }
        activityTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await api.post(snapshot, path: "/api/activity/playback", session: session)
            } catch APIError.httpStatus(401, _) {
                if !Task.isCancelled, self.session == session { await verifySession(session) }
            } catch {
                // Activity snapshots are sent online only. The next state or heartbeat supersedes them.
            }
            activityTask = nil
            sendActivity()
        }
    }
}
