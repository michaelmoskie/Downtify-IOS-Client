import Combine
import Foundation
import UIKit

struct OfflineMedia: Codable, Equatable {
    let length: Int64
    let mime: String
    let type: String
    let fileExtension: String
    let etag: String?
    let quality: PlaybackQuality
}

enum OfflineDownloadFailure: String, Error, Codable, Equatable {
    case network, interrupted, unauthorized, unsupportedFormat, invalidFile, insufficientStorage, fileSystem
}

struct OfflineDownload: Codable, Equatable, Identifiable {
    enum State: Codable, Equatable {
        case preparing, transferring, ready, cancelled, failed(OfflineDownloadFailure)
    }

    struct Scope: Codable, Equatable {
        let serverID: String
        let username: String?
        let deviceID: String

        init(_ session: DeviceSession) {
            serverID = session.serverID
            username = session.username?.lowercased()
            deviceID = session.deviceID
        }
    }

    let id: UUID
    let track: LibraryTrack
    let scope: Scope
    let requestedQuality: PlaybackQuality
    var state: State = .preparing
    var media: OfflineMedia?
    var receivedBytes: Int64 = 0

    var expectedBytes: Int64? { media?.length }

    var pending: Bool { state == .preparing || state == .transferring }
}

@MainActor
protocol OfflinePlaybackProviding: AnyObject {
    func offlineStream(trackID: String, session: DeviceSession) -> PlaybackStream?
}

@MainActor
final class OfflineDownloads: ObservableObject, OfflinePlaybackProviding {
    static let backgroundIdentifier = "app.downtify.ios.offline"
    static let live = OfflineDownloads()

    @Published private var records: [OfflineDownload] = []
    @Published private(set) var storageFailure: OfflineDownloadFailure?

    private let directory: URL
    private let api: any OfflineDownloadPreparing
    private let availableCapacity: (URL) -> Int64?
    private let makeConfiguration: (Bool) -> URLSessionConfiguration
    private var loaded = false
    @Published private var session: DeviceSession?
    private var jobs: [UUID: URLSessionDownloadTask] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var observation: Task<Void, Never>?
    private var lastProgressSave = Date.distantPast
    private var backgroundCompletion: (() -> Void)?
    private var reconnecting = false

    private lazy var delegate = OfflineTransferDelegate(owner: self)
    private lazy var background = makeSession(background: true)
    private lazy var foreground = makeSession(background: false)

    init(directory: URL? = nil, api: any OfflineDownloadPreparing = OfflineDownloadAPI(),
         availableCapacity: @escaping (URL) -> Int64? = {
             try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                 .volumeAvailableCapacityForImportantUsage
         },
         configuration: ((Bool) -> URLSessionConfiguration)? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "OfflineMedia", directoryHint: .isDirectory)
        self.api = api
        self.availableCapacity = availableCapacity
        makeConfiguration = configuration ?? { background in
            background ? .background(withIdentifier: Self.backgroundIdentifier) : .ephemeral
        }
    }

    var currentDownloads: [OfflineDownload] {
        guard let session else { return [] }
        return records.filter { $0.scope == .init(session) }
    }

    var storedBytes: Int64 {
        records.reduce(0) { total, record in
            total + (record.state == .ready ? record.receivedBytes : 0)
        }
    }

    var pendingBytes: Int64 {
        records.reduce(0) { total, record in
            total + (record.state == .transferring ? max(0, (record.expectedBytes ?? 0) - record.receivedBytes) : 0)
        }
    }

    var wifiOnly = false
    var byteLimit: Int64?
    var verifySession: ((DeviceSession) async -> Void)?

    func observeSessions(_ updates: @escaping () async throws -> AsyncStream<DeviceSession?>) {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            defer { self?.observation = nil }
            guard let stream = try? await updates() else { return }
            for await session in stream {
                self?.setSession(session)
                self?.reconnect()
            }
        }
    }

    func setSession(_ session: DeviceSession?) {
        let previous = self.session
        self.session = session
        guard openStore() else { return }
        // Scope includes the paired device, so a new pairing never inherits files from a revoked session.
        let scope = session.map(OfflineDownload.Scope.init)
        var changed = false
        for record in records where record.scope != scope {
            stop(record.id)
            do {
                try removeFile(record)
                records.removeAll { $0.id == record.id }
                changed = true
            } catch {
                storageFailure = Self.failure(error)
            }
        }
        if let previous, previous != session {
            for index in records.indices where records[index].scope == scope && records[index].pending {
                stop(records[index].id)
                records[index].state = .failed(.interrupted)
                changed = true
            }
        }
        if changed { save() }
    }

    func reconnect(completion: (() -> Void)? = nil) {
        if let completion { backgroundCompletion = completion }
        guard !reconnecting else { return }
        _ = openStore()
        reconnecting = true
        let pending = Set(records.filter(\.pending).map(\.id))
        background.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.reattach(tasks, previouslyPending: pending)
                self?.reconnecting = false
            }
        }
    }

    func persistProgress() {
        if loaded { save() }
    }

    @discardableResult
    func enqueue(_ track: LibraryTrack, quality: PlaybackQuality = .original) throws -> UUID {
        guard let session else { throw PlaybackFailure.signedOut }
        guard openStore() else { throw storageFailure ?? .fileSystem }
        let scope = OfflineDownload.Scope(session)
        if let existing = records.first(where: { $0.scope == scope && $0.track.id == track.id }) {
            if existing.pending || existing.state == .ready { return existing.id }
            return try retry(existing.id)
        }
        return try start(track, quality: quality, session: session)
    }

    @discardableResult
    func retry(_ id: UUID) throws -> UUID {
        guard let session else { throw PlaybackFailure.signedOut }
        guard let record = currentDownloads.first(where: { $0.id == id }),
              !record.pending, record.state != .ready else { throw OfflineDownloadFailure.interrupted }
        return try start(record.track, quality: record.requestedQuality, session: session, replacing: id)
    }

    func cancel(_ id: UUID) {
        guard let index = currentIndex(id), records[index].state != .ready else { return }
        stop(id)
        records[index].state = .cancelled
        save()
    }

    func delete(_ id: UUID) throws {
        guard let index = currentIndex(id) else { return }
        try removeFile(records[index])
        stop(id)
        records.remove(at: index)
        try writeManifest()
    }

    func offlineStream(trackID: String, session: DeviceSession) -> PlaybackStream? {
        guard openStore(), let index = records.firstIndex(where: {
            $0.track.id == trackID && $0.scope == .init(session) && $0.state == .ready
        }), let media = records[index].media, let url = fileURL(records[index]) else { return nil }

        do {
            guard try Self.fileSize(url) == media.length else { throw OfflineDownloadFailure.invalidFile }
        } catch {
            // Protected data can be temporarily unavailable after a reboot; leave it intact.
            if (error as? CocoaError)?.code == .fileReadNoPermission { return nil }
            markFailed(records[index].id, .invalidFile)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return PlaybackStream(contentType: media.type, fileExtension: media.fileExtension, length: media.length,
                              quality: media.quality, availableQualities: [media.quality], fileURL: url) { range in
            guard range.lowerBound >= 0, range.upperBound < media.length else { throw PlaybackFailure.invalidStream }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let length = Int(range.upperBound - range.lowerBound + 1)
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw PlaybackFailure.invalidStream
            }
            return data
        }
    }

    private func start(_ track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession,
                       replacing oldID: UUID? = nil) throws -> UUID {
        let previous = records
        let id = UUID()
        if let oldID { records.removeAll { $0.id == oldID } }
        records.append(OfflineDownload(id: id, track: track, scope: .init(session), requestedQuality: quality))
        do { try writeManifest() } catch {
            records = previous
            throw Self.failure(error)
        }

        let wifiOnly = wifiOnly
        preparations[id] = Task { [weak self, api] in
            defer { self?.preparations[id] = nil }
            do {
                let source = try await api.prepare(track: track, quality: quality, session: session, wifiOnly: wifiOnly)
                try Task.checkCancellation()
                guard let self else { return }
                guard self.session == session else { throw OfflineDownloadFailure.interrupted }
                try begin(id, source: source)
            } catch is CancellationError {
                return
            } catch {
                let failure = Self.failure(error)
                self?.markFailed(id, failure)
                if failure == .unauthorized { await self?.verifySession?(session) }
            }
        }
        return id
    }

    private func begin(_ id: UUID, source: OfflineDownloadSource) throws {
        guard let index = currentIndex(id), records[index].state == .preparing else { return }
        let length = source.media.length
        let reserved = records.reduce(Int64(0)) {
            $0 + ($1.state == .transferring ? ($1.expectedBytes ?? 0) : 0)
        }
        guard length > 0,
              byteLimit.map({ length <= max(0, $0 - storedBytes - reserved) }) ?? true,
              availableCapacity(directory).map({ length <= max(0, $0 - pendingBytes) }) ?? true else {
            throw OfflineDownloadFailure.insufficientStorage
        }

        let task = (source.background ? background : foreground).downloadTask(with: source.request)
        task.taskDescription = id.uuidString
        records[index].media = source.media
        records[index].state = .transferring
        do { try writeManifest() } catch {
            task.cancel()
            throw error
        }
        jobs[id] = task
        task.resume()
    }

    func reattach(_ tasks: [URLSessionTask], previouslyPending: Set<UUID>) {
        guard openStore() else { return }
        var changed = false
        for task in tasks {
            guard let download = task as? URLSessionDownloadTask, let id = taskID(task),
                  let index = records.firstIndex(where: { $0.id == id && $0.state == .transferring }) else {
                task.cancel()
                continue
            }
            jobs[id] = download
            if task.state == .suspended { task.resume() }
            let progress = min(max(0, task.countOfBytesReceived), records[index].expectedBytes ?? 0)
            if progress > records[index].receivedBytes {
                records[index].receivedBytes = progress
                changed = true
            }
        }
        for index in records.indices {
            let record = records[index]
            guard previouslyPending.contains(record.id), record.pending, jobs[record.id] == nil,
                  preparations[record.id] == nil else { continue }
            // Recover an already verified file if the process stopped after the move, before writing the manifest.
            if let url = fileURL(record), let length = record.expectedBytes,
               (try? Self.fileSize(url)) == length {
                records[index].state = .ready
                records[index].receivedBytes = length
            } else {
                records[index].state = .failed(.interrupted)
            }
            changed = true
        }
        if changed { save() }
    }

    func progress(_ task: URLSessionDownloadTask, bytes: Int64) {
        guard let id = taskID(task), let index = records.firstIndex(where: {
            $0.id == id && $0.state == .transferring
        }), let length = records[index].expectedBytes else { return }
        // Error response bodies are not audio bytes. Let the completion path classify the status.
        if let response = task.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { return }
        guard bytes <= length else {
            stop(id)
            task.cancel()
            markFailed(id, .invalidFile)
            return
        }
        records[index].receivedBytes = max(0, bytes)
        if Date().timeIntervalSince(lastProgressSave) >= 1 {
            lastProgressSave = Date()
            save()
        }
    }

    func finish(_ task: URLSessionDownloadTask, temporaryURL: URL) {
        guard openStore(), let id = taskID(task), let index = records.firstIndex(where: {
            $0.id == id && ($0.state == .transferring || $0.state == .failed(.interrupted))
        }), let media = records[index].media, let url = fileURL(records[index]) else { return }
        do {
            guard let response = task.response as? HTTPURLResponse,
                  response.url == task.originalRequest?.url else { throw OfflineDownloadFailure.invalidFile }
            if response.statusCode == 401 {
                if let session, records[index].scope == .init(session) {
                    Task { await verifySession?(session) }
                }
                throw OfflineDownloadFailure.unauthorized
            }
            if (500...599).contains(response.statusCode) { throw OfflineDownloadFailure.network }
            try Self.validate(media, response: response, temporaryURL: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: url)
            records[index].state = .ready
            records[index].receivedBytes = media.length
            save()
        } catch {
            markFailed(id, Self.failure(error))
        }
    }

    static func validate(_ media: OfflineMedia, response: HTTPURLResponse, temporaryURL: URL) throws {
        guard (response.mimeType?.lowercased() ?? "") == media.mime,
              media.etag == nil || OfflineDownloadAPI.strongETag(response) == media.etag,
              try fileSize(temporaryURL) == media.length else { throw OfflineDownloadFailure.invalidFile }
        switch response.statusCode {
        case 200:
            guard response.expectedContentLength == media.length else { throw OfflineDownloadFailure.invalidFile }
        case 206:
            // URLSession can deliver a full assembled file with the response for the last resumed range.
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  range.hasPrefix("bytes "), let dash = range.firstIndex(of: "-"),
                  let start = Int64(range.dropFirst(6).prefix(while: { $0 != "-" })),
                  start >= 0, start < media.length,
                  range[range.index(after: dash)...] == "\(media.length - 1)/\(media.length)",
                  response.expectedContentLength == media.length - start else { throw OfflineDownloadFailure.invalidFile }
        default:
            throw OfflineDownloadFailure.invalidFile
        }
    }

    func completed(_ task: URLSessionTask, error: Error?) {
        guard let id = taskID(task) else { return }
        jobs[id] = nil
        guard records.contains(where: {
            $0.id == id && ($0.state == .transferring || $0.state == .failed(.interrupted))
        }) else { return }
        markFailed(id, error.map(Self.failure) ?? .interrupted)
    }

    func didFinishBackgroundEvents() {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }

    private func stop(_ id: UUID) {
        preparations.removeValue(forKey: id)?.cancel()
        jobs.removeValue(forKey: id)?.cancel()
    }

    private func markFailed(_ id: UUID, _ failure: OfflineDownloadFailure) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.state != .cancelled }) else { return }
        records[index].state = .failed(failure)
        save()
    }

    private func currentIndex(_ id: UUID) -> Int? {
        guard let session else { return nil }
        return records.firstIndex { $0.id == id && $0.scope == .init(session) }
    }

    private func taskID(_ task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func fileURL(_ record: OfflineDownload) -> URL? {
        guard let ext = record.media?.fileExtension,
              !ext.isEmpty, ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) })
        else { return nil }
        return directory.appending(path: record.id.uuidString).appendingPathExtension(ext)
    }

    private func removeFile(_ record: OfflineDownload) throws {
        guard let url = fileURL(record) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // An absent file already satisfies deletion.
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        // URL.resourceValues can cache the previous size on the same URL instance.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw OfflineDownloadFailure.invalidFile
        }
        return size.int64Value
    }

    private var manifest: URL { directory.appending(path: "downloads.json") }

    private func openStore() -> Bool {
        if loaded { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var folder = directory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try folder.setResourceValues(resources)
            do {
                records = try JSONDecoder().decode([OfflineDownload].self, from: Data(contentsOf: manifest))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                records = []
            }
            loaded = true
            storageFailure = nil
            return true
        } catch {
            storageFailure = Self.failure(error)
            return false
        }
    }

    private func writeManifest() throws {
        do {
            try JSONEncoder().encode(records).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageFailure = nil
        } catch {
            storageFailure = Self.failure(error)
            throw error
        }
    }

    private func save() {
        do { try writeManifest() } catch { storageFailure = Self.failure(error) }
    }

    private static func failure(_ error: Error) -> OfflineDownloadFailure {
        if let error = error as? OfflineDownloadFailure { return error }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .interrupted
            case .cannotCreateFile, .cannotWriteToFile, .downloadDecodingFailedToComplete:
                if let cause = error.userInfo[NSUnderlyingErrorKey] as? Error { return failure(cause) }
                return .fileSystem
            default: return .network
            }
        }
        if let error = error as? CocoaError {
            return error.code == .fileWriteOutOfSpace ? .insufficientStorage : .fileSystem
        }
        if (error as NSError).domain == NSPOSIXErrorDomain, (error as NSError).code == Int(ENOSPC) {
            return .insufficientStorage
        }
        if let error = error as? APIError {
            switch error {
            case .httpStatus(401, _): return .unauthorized
            case .transportFailure, .httpStatus: return .network
            default: return .invalidFile
            }
        }
        if let error = error as? PlaybackFailure, error == .unsupportedFormat { return .unsupportedFormat }
        return .invalidFile
    }

    private func makeSession(background: Bool) -> URLSession {
        let configuration = makeConfiguration(background)
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.sessionSendsLaunchEvents = background
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
    }
}

private final class OfflineTransferDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var owner: OfflineDownloads?

    init(owner: OfflineDownloads) { self.owner = owner }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is valid only during this callback. The delegate queue is the main queue.
        MainActor.assumeIsolated { owner?.finish(downloadTask, temporaryURL: location) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated { owner?.progress(downloadTask, bytes: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { owner?.completed(task, error: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { owner?.didFinishBackgroundEvents() }
    }
}

@MainActor
final class OfflineDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineDownloads.backgroundIdentifier else { completionHandler(); return }
        OfflineDownloads.live.reconnect(completion: completionHandler)
    }
}
