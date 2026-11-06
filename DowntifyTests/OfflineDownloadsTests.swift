import Foundation
import XCTest
@testable import Downtify

final class OfflineDownloadsTests: XCTestCase {
    @MainActor
    func testRelaunchRestoresProgressAndRetryCreatesFreshAttempt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = record(state: .transferring, bytes: 3)
        try seed([transfer], in: directory)
        let downloads = OfflineDownloads(directory: directory, api: PendingPreparation())
        downloads.setSession(session())
        XCTAssertEqual(downloads.currentDownloads.first?.receivedBytes, 3)
        XCTAssertEqual(downloads.pendingBytes, 5)

        let task = URLSession.shared.downloadTask(with: URL(string: "https://localhost/test")!)
        task.taskDescription = transfer.id.uuidString
        downloads.progress(task, bytes: 5)
        task.cancel()

        let relaunched = OfflineDownloads(directory: directory, api: PendingPreparation())
        relaunched.setSession(session())
        XCTAssertEqual(relaunched.currentDownloads.first?.receivedBytes, 5)
        relaunched.reattach([], previouslyPending: [transfer.id])
        XCTAssertEqual(relaunched.currentDownloads.first?.state, .failed(.interrupted))
        XCTAssertEqual(relaunched.pendingBytes, 0)

        let next = try relaunched.retry(transfer.id)
        XCTAssertNotEqual(next, transfer.id)
        XCTAssertEqual(relaunched.currentDownloads.first?.receivedBytes, 0)
        relaunched.cancel(next)
        let reopened = OfflineDownloads(directory: directory)
        reopened.setSession(session())
        XCTAssertEqual(reopened.currentDownloads.map(\.state), [.cancelled])
    }

    @MainActor
    func testRecoverCompletedFileAndPlayWithoutServerThenDelete() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = record(state: .transferring, bytes: 5)
        try seed([transfer], in: directory)
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let file = directory.appending(path: "\(transfer.id.uuidString).mp3")
        try data.write(to: file)

        let downloads = OfflineDownloads(directory: directory)
        let session = session()
        downloads.setSession(session)
        downloads.reattach([], previouslyPending: [transfer.id])
        XCTAssertEqual(downloads.currentDownloads.first?.state, .ready)
        XCTAssertEqual(downloads.storedBytes, 8)
        XCTAssertEqual(downloads.pendingBytes, 0)

        let transport = ScriptedDownloadTransport([])
        let resolver = PlaybackStreamResolver(transport: transport, offline: downloads)
        let stream = try await resolver.resolve(track: transfer.track, quality: .original, session: session)
        XCTAssertEqual(stream.fileURL, file)
        let slice = try await stream.read(3...5)
        XCTAssertEqual(slice, Data([3, 4, 5]))
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)

        let anotherDevice = self.session(device: "new-pairing")
        XCTAssertNil(downloads.offlineStream(trackID: transfer.track.id, session: anotherDevice))
        try downloads.delete(transfer.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(downloads.storedBytes, 0)
        XCTAssertNil(downloads.offlineStream(trackID: transfer.track.id, session: session))
    }

    @MainActor
    func testDiskCapacityAndStorageLimitRejectBeforeStartingTransfer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = OfflineDownloads(directory: directory, api: PreparedMedia(media: media),
                                         availableCapacity: { _ in 7 })
        downloads.setSession(session())
        let id = try downloads.enqueue(track())
        try await waitForFailure(id, in: downloads)
        XCTAssertEqual(downloads.currentDownloads.first?.state, .failed(.insufficientStorage))
        XCTAssertEqual(downloads.storedBytes, 0)

        let secondDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        let limited = OfflineDownloads(directory: secondDirectory, api: PreparedMedia(media: media),
                                       availableCapacity: { _ in 100 })
        limited.byteLimit = 7
        limited.setSession(session())
        let limitedID = try limited.enqueue(track())
        try await waitForFailure(limitedID, in: limited)
        XCTAssertEqual(limited.currentDownloads.first?.state, .failed(.insufficientStorage))
    }

    @MainActor
    func testTransferFailureKeepsProgressAndCorruptSavedFileIsNotPlayable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = record(state: .transferring, bytes: 3)
        try seed([transfer], in: directory)
        let downloads = OfflineDownloads(directory: directory)
        downloads.setSession(session())
        let task = URLSession.shared.downloadTask(with: URL(string: "https://localhost/test")!)
        task.taskDescription = transfer.id.uuidString
        downloads.completed(task, error: URLError(.networkConnectionLost))
        task.cancel()
        XCTAssertEqual(downloads.currentDownloads.first?.state, .failed(.network))
        XCTAssertEqual(downloads.currentDownloads.first?.receivedBytes, 3)

        let saved = record(state: .ready, bytes: 8)
        try seed([saved], in: directory)
        let file = directory.appending(path: "\(saved.id.uuidString).mp3")
        try Data([0, 1, 2]).write(to: file)
        let reopened = OfflineDownloads(directory: directory)
        reopened.setSession(session())
        XCTAssertNil(reopened.offlineStream(trackID: saved.track.id, session: session()))
        XCTAssertEqual(reopened.currentDownloads.first?.state, .failed(.invalidFile))
        XCTAssertEqual(reopened.storedBytes, 0)
    }

    @MainActor
    func testIntegrityRejectsTruncatedPartialAndChangedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "download")
        try Data(repeating: 1, count: 8).write(to: file)
        let url = URL(string: "https://localhost/audio")!
        func response(status: Int = 200, mime: String = "audio/mpeg", etag: String = "\"version\"") -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": mime, "Content-Length": "8", "ETag": etag])!
        }
        XCTAssertNoThrow(try OfflineDownloads.validate(media, response: response(), temporaryURL: file))
        XCTAssertThrowsError(try OfflineDownloads.validate(media, response: response(status: 206), temporaryURL: file))
        let resumed = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "audio/mpeg", "Content-Length": "5", "Content-Range": "bytes 3-7/8", "ETag": "\"version\""
        ])!
        XCTAssertNoThrow(try OfflineDownloads.validate(media, response: resumed, temporaryURL: file))
        XCTAssertThrowsError(try OfflineDownloads.validate(media, response: response(mime: "text/html"), temporaryURL: file))
        XCTAssertThrowsError(try OfflineDownloads.validate(media, response: response(etag: "\"changed\""), temporaryURL: file))
        try Data(repeating: 1, count: 7).write(to: file)
        XCTAssertThrowsError(try OfflineDownloads.validate(media, response: response(), temporaryURL: file))
    }

    func testDownloadPreflightUsesSignedURLWithoutBearerAndKeepsReverseProxyPath() async throws {
        let transport = ScriptedDownloadTransport([
            .init(json: info(signed: true)),
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "8", "ETag": "\"version\""]),
            .init(json: #"{"urls":["/api/v1/tracks/song/stream?download=true&exp=1789000000&kid=device&sig=abc"]}"#)
        ])
        let source = try await OfflineDownloadAPI(transport: transport).prepare(
            track: track(), quality: .original, session: session(), wifiOnly: true
        )
        let requests = await transport.requests
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].httpMethod, "HEAD")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://music.local/proxy/api/v1/tracks/song/stream?download=true")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertFalse(requests[1].allowsCellularAccess)
        XCTAssertEqual(requests[2].url?.path, "/proxy/api/v1/sign")
        let signed = try XCTUnwrap(source.request.url)
        XCTAssertEqual(signed.host, "music.local")
        XCTAssertEqual(signed.path, "/proxy/api/v1/tracks/song/stream")
        XCTAssertNil(source.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(source.background)
        XCTAssertEqual(source.media, media)
    }

    func testUnsignedServerFallsBackAndQueueCallsStayOnServerRoutes() async throws {
        let transport = ScriptedDownloadTransport([
            .init(json: info(signed: false)),
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "8"]),
            .init(json: info(signed: false)),
            .init(json: #"[{"song":{"id":"queue-id","title":"Song"},"status":"done","progress":100,"filename":"file.mp3"}]"#),
            .init(json: info(signed: false)),
            .init(json: #""file.mp3""#)
        ])
        let source = try await OfflineDownloadAPI(transport: transport).prepare(
            track: track(), quality: .original, session: session(), wifiOnly: false
        )
        XCTAssertFalse(source.background)
        XCTAssertEqual(source.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

        let queue = ServerDownloadQueue(transport: transport)
        let jobs = try await queue.jobs(session: session())
        XCTAssertEqual(jobs.first?.song.id, "queue-id")
        let filename = try await queue.requestTrack(link: URL(string: "https://example.com/music?song=a+b&b=c")!, session: session())
        XCTAssertEqual(filename, "file.mp3")
        let requests = await transport.requests
        XCTAssertEqual(requests[3].url?.path, "/proxy/api/queue")
        XCTAssertEqual(requests[5].url?.path, "/proxy/api/download/url")
        XCTAssertEqual(requests[5].httpMethod, "POST")
        XCTAssertTrue(requests[5].url?.absoluteString.contains("%2B") == true)
        XCTAssertEqual(requests[5].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value },
                       "https://example.com/music?song=a+b&b=c")
    }

    @MainActor
    private func waitForFailure(_ id: UUID, in downloads: OfflineDownloads) async throws {
        for _ in 0..<100 {
            if case .failed = downloads.currentDownloads.first(where: { $0.id == id })?.state { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected a failed download")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func seed(_ downloads: [OfflineDownload], in directory: URL) throws {
        try JSONEncoder().encode(downloads).write(to: directory.appending(path: "downloads.json"))
    }

    private var media: OfflineMedia {
        OfflineMedia(length: 8, mime: "audio/mpeg", type: "public.mp3",
                     fileExtension: "mp3", etag: "\"version\"", quality: .original)
    }

    private func session(device: String = "device") -> DeviceSession {
        DeviceSession(baseAddress: "https://music.local/proxy", serverID: "server", serverName: "Music",
                      deviceID: device, username: "user", role: nil, token: "test-token", allowsInsecureHTTP: false)
    }

    private func track() -> LibraryTrack {
        LibraryTrack(id: "song", file: "Song.mp3", title: "Song", artist: "Artist", artists: [],
                     album: "", albumArtist: "", albumID: "", artistID: "", trackNumber: 0, year: "",
                     duration: 60, codec: "mp3", bitrate: 0, sampleRate: 0, channels: 0, size: 8,
                     added: 0, hasCover: false, isExplicit: false, playlists: [])
    }

    private func record(state: OfflineDownload.State, bytes: Int64) -> OfflineDownload {
        OfflineDownload(id: UUID(), track: track(), scope: .init(session()), requestedQuality: .original,
                        state: state, media: media, receivedBytes: bytes)
    }

    private func info(signed: Bool) -> String {
        """
        {"product":"Downtify","server_id":"server","api_version":1,"capabilities":{"signed_urls":\(signed)}}
        """
    }
}

private struct PendingPreparation: OfflineDownloadPreparing {
    func prepare(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession,
                 wifiOnly: Bool) async throws -> OfflineDownloadSource {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private struct PreparedMedia: OfflineDownloadPreparing {
    let media: OfflineMedia

    func prepare(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession,
                 wifiOnly: Bool) async throws -> OfflineDownloadSource {
        OfflineDownloadSource(request: URLRequest(url: URL(string: "https://localhost/media")!),
                              background: false, media: media)
    }
}

private actor ScriptedDownloadTransport: HTTPDataLoading {
    struct Reply {
        var json = ""
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        return (Data(reply.json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                      headerFields: reply.headers)!)
    }
}
