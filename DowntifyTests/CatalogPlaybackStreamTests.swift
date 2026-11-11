import Foundation
import XCTest
@testable import Downtify

final class CatalogPlaybackStreamTests: XCTestCase {
    func testCatalogStreamURLUsesProviderIDAndDuration() throws {
        let address = try ServerAddress("https://example.test/music")
        let url = try PlaybackStreamResolver.catalogStreamURL(address: address, videoID: "abcdefghijk", duration: 123.5)
        XCTAssertEqual(url.path, "/music/api/stream/file")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "video_id", value: "abcdefghijk"), URLQueryItem(name: "duration", value: "123.5")])
        XCTAssertThrowsError(try PlaybackStreamResolver.catalogStreamURL(address: address, videoID: "library-track-id", duration: 12))
    }

    func testCatalogStreamUsesRangeAndAuthorizationOnlyForServerURL() async throws {
        let loader = CatalogPlaybackLoader()
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: "alice", role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"youtube_music","song_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":123,"url":"https://youtube.com/watch?v=abcdefghijk"}"#)

        let stream = try await PlaybackStreamResolver(transport: loader).resolve(catalogSong: song, quality: .original, session: session)
        XCTAssertEqual(stream.length, 4)
        let bytes = try await stream.read(0...3)
        XCTAssertEqual(bytes, Data("test".utf8))
        let requests = loader.requests
        let streamRequest = try XCTUnwrap(requests.first { $0.url?.path == "/music/api/stream/file" })
        XCTAssertEqual(streamRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(streamRequest.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(streamRequest.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "abcdefghijk")
        XCTAssertFalse(requests.contains { $0.url?.host == "youtube.com" && $0.value(forHTTPHeaderField: "Authorization") != nil })
    }

    func testInvalidSongIDFallsBackToAuthenticatedCatalogSearch() async throws {
        let loader = CatalogPlaybackLoader()
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"deezer","song_id":"123456","name":"Roads","artist":"Portishead","duration":123,"url":"https://deezer.test/track/1"}"#)

        _ = try await PlaybackStreamResolver(transport: loader).resolve(catalogSong: song, quality: .original, session: session)
        let search = try XCTUnwrap(loader.requests.first { $0.url?.path == "/music/api/songs/search" })
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(search.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "query", value: "Portishead Roads")])
        XCTAssertEqual(search.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testAmbiguousProviderIDUsesSearchForStreamingAndPrefetch() async throws {
        let loader = CatalogPlaybackLoader()
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"deezer","song_id":"12345678901","name":"Roads","artist":"Portishead","duration":123}"#)
        let resolver = PlaybackStreamResolver(transport: loader)
        _ = try await resolver.resolve(catalogSong: song, quality: .original, session: session)
        try await resolver.prefetch(catalogSong: song, session: session)
        XCTAssertEqual(loader.requests.filter { $0.url?.path == "/music/api/songs/search" }.count, 2)
        let stream = try XCTUnwrap(loader.requests.first { $0.url?.path == "/music/api/stream/file" })
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(stream.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "abcdefghijk")
        let prefetch = try XCTUnwrap(loader.requests.first { $0.url?.path == "/music/api/stream/prefetch" })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(prefetch.httpBody)) as? [String: String], ["video_id": "abcdefghijk"])
    }

    func testServerMismatchStopsBeforeCatalogBearerRequest() async throws {
        let loader = CatalogPlaybackLoader(serverID: "other")
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"youtube_music","song_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":123}"#)

        do {
            _ = try await PlaybackStreamResolver(transport: loader).resolve(catalogSong: song, quality: .original, session: session)
            XCTFail("Expected server identity verification to fail")
        } catch let failure as PlaybackFailure {
            XCTAssertEqual(failure, .differentServer)
        }
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertNil(loader.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedStreamStatusIsPreservedForSessionRevocation() async throws {
        let loader = CatalogPlaybackLoader(streamStatus: 401)
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"youtube_music","song_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":123}"#)
        do {
            _ = try await PlaybackStreamResolver(transport: loader).resolve(catalogSong: song, quality: .original, session: session)
            XCTFail("Expected unauthorized response")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(401, retryAfter: nil))
        }
        let streamRequest = try XCTUnwrap(loader.requests.first { $0.url?.path == "/music/api/stream/file" })
        XCTAssertEqual(streamRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testProviderSearchHTTPFailureIsPreserved() async throws {
        let loader = CatalogPlaybackLoader(searchStatus: 502)
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"deezer","song_id":"123456","name":"Roads","artist":"Portishead","duration":123}"#)
        do {
            _ = try await PlaybackStreamResolver(transport: loader).resolve(catalogSong: song, quality: .original, session: session)
            XCTFail("Expected provider search failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpStatus(502, retryAfter: nil))
        }
    }

    func testLibraryOnlyPolicyBlocksCatalogStreamAndPrefetch() async throws {
        let loader = CatalogPlaybackLoader(libraryOnly: true)
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"youtube_music","song_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":123}"#)
        do {
            _ = try await PlaybackStreamResolver(transport: loader).resolve(catalogSong: song, quality: .original, session: session)
            XCTFail("Expected library-only policy to block catalog playback")
        } catch let error as CatalogAPIError {
            XCTAssertEqual(error, .libraryOnly)
        }
        try await PlaybackStreamResolver(transport: loader).prefetch(catalogSong: song, session: session)
        XCTAssertFalse(loader.requests.contains { $0.url?.path == "/music/api/stream/file" || $0.url?.path == "/music/api/stream/prefetch" })
        XCTAssertTrue(loader.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testPrefetchUsesServerRouteAndCatalogJSONBody() async throws {
        let loader = CatalogPlaybackLoader()
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"youtube_music","song_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":123}"#)
        try await PlaybackStreamResolver(transport: loader).prefetch(catalogSong: song, session: session)

        let request = try XCTUnwrap(loader.requests.first { $0.url?.path == "/music/api/stream/prefetch" })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["video_id": "abcdefghijk"])
        XCTAssertFalse(loader.requests.contains { $0.url?.host == "youtube.com" && $0.value(forHTTPHeaderField: "Authorization") != nil })
    }

    func testCancelledCatalogPrefetchStopsBeforeSendingBearerRequest() async throws {
        let loader = CatalogPlaybackLoader()
        let session = DeviceSession(baseAddress: "https://example.test/music", serverID: "srv", serverName: "Test",
                                    deviceID: "device", username: nil, role: "CLIENT", token: "secret", allowsInsecureHTTP: false)
        let song = try decodeSong(#"{"source":"youtube_music","song_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":123}"#)
        let task = Task {
            try await PlaybackStreamResolver(transport: loader).prefetch(catalogSong: song, session: session)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(loader.requests.contains { $0.url?.path == "/music/api/stream/prefetch" })
    }

    private func decodeSong(_ json: String) throws -> CatalogSong {
        try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
    }
}

private final class CatalogPlaybackLoader: HTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }

    private let serverID: String
    private let libraryOnly: Bool
    private let searchStatus: Int
    private let streamStatus: Int

    init(serverID: String = "srv", libraryOnly: Bool = false, searchStatus: Int = 200, streamStatus: Int = 206) {
        self.serverID = serverID
        self.libraryOnly = libraryOnly
        self.searchStatus = searchStatus
        self.streamStatus = streamStatus
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); storedRequests.append(request); lock.unlock()
        let url = try XCTUnwrap(request.url)
        let data: Data
        let status: Int
        var headers: [String: String] = [:]
        if url.path == "/music/api/server/info" {
            let payload: [String: Any] = ["product": "Downtify", "api_version": 1, "server_id": serverID, "library_only": libraryOnly]
            data = try JSONSerialization.data(withJSONObject: payload)
            status = 200
        } else if url.path == "/music/api/songs/search" {
            data = Data(#"[{"source":"youtube_music","song_id":"candidate-song","youtube_id":"abcdefghijk","name":"Roads","artist":"Portishead","duration":125,"url":"https://youtube.com/watch?v=abcdefghijk"}]"#.utf8)
            status = searchStatus
        } else {
            status = streamStatus
            let requested = request.value(forHTTPHeaderField: "Range") == "bytes=0-1" ? 0...1 : 0...3
            if streamStatus == 206 {
                data = Data("test".utf8).subdata(in: requested.lowerBound..<(requested.upperBound + 1))
                headers["Content-Range"] = "bytes \(requested.lowerBound)-\(requested.upperBound)/4"
                headers["Content-Type"] = "audio/mpeg"
                headers["ETag"] = "\"v1\""
            } else {
                data = Data()
            }
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        return (data, response)
    }
}
