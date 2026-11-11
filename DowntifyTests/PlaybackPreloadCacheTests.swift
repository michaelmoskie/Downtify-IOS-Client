import Foundation
import XCTest
@testable import Downtify

final class PlaybackPreloadCacheTests: XCTestCase {
    func testPublishesExactBytesOnlyAfterAllChunksAreWritten() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ReadGate()
        let length = PlaybackCache.blockSize + 3
        let key = makeKey()
        let task = Task {
            try await cache.store(makeStream(length: length) { range in
                if range.lowerBound != 0 { await gate.wait() }
                return Data(repeating: range.lowerBound == 0 ? 1 : 2, count: Int(range.count))
            }, for: key)
        }
        await gate.waitUntilReading()
        let partial = await cache.stream(for: key)
        XCTAssertNil(partial)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)

        await gate.resume()
        try await task.value
        let cached = await cache.stream(for: key)
        let stream = try XCTUnwrap(cached)
        let boundary = PlaybackCache.blockSize - 1
        let data = try await stream.read(boundary...(length - 1))
        XCTAssertEqual(data, Data([1, 2, 2, 2]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stream.fileURL)).count, Int(length))
    }

    func testCancellationAndInvalidByteCountRemovePartialFiles() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = makeKey()
        let gate = ReadGate()
        let task = Task {
            try await cache.store(makeStream(length: 10) { _ in
                await gate.wait()
                return Data(repeating: 1, count: 10)
            }, for: key)
        }
        await gate.waitUntilReading()
        task.cancel()
        await gate.resume()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        do {
            try await cache.store(makeStream(length: 10) { _ in Data([1]) }, for: key)
            XCTFail("Expected invalid stream")
        } catch PlaybackFailure.invalidStream {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testReservesBudgetAndRetainsFilesInUseAfterEviction() async throws {
        let (cache, directory) = makeCache(byteLimit: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = makeKey()
        let other = makeKey(media: "another")
        let gate = ReadGate()
        let task = Task {
            try await cache.store(makeStream(length: 6) { range in
                await gate.wait()
                return Data(repeating: 1, count: Int(range.count))
            }, for: key)
        }
        await gate.waitUntilReading()
        try await cache.store(makeStream(length: 5), for: other)
        let otherWasStored = await cache.contains(other)
        XCTAssertFalse(otherWasStored)
        await gate.resume()
        try await task.value

        let cached = await cache.stream(for: key)
        let stream = try XCTUnwrap(cached)
        let url = try XCTUnwrap(stream.fileURL)
        await cache.retain([other], byteLimit: 10)
        let retired = await cache.contains(key)
        XCTAssertFalse(retired)
        let bytes = try await stream.read(0...5)
        XCTAssertEqual(bytes.count, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try await cache.store(makeStream(length: 11), for: other)
        try await cache.store(makeStream(length: 5), for: other)
        let fitsWithLeasedFile = await cache.contains(other)
        XCTAssertFalse(fitsWithLeasedFile)
    }

    func testCacheLookupIsScopedToServerAndAccount() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = makeKey()
        try await cache.store(makeStream(length: 10), for: key)
        let own = await cache.contains(key)
        let otherAccount = await cache.contains(makeKey(account: "other"))
        let otherServer = await cache.contains(makeKey(server: "other"))
        XCTAssertTrue(own)
        XCTAssertFalse(otherAccount)
        XCTAssertFalse(otherServer)
    }

    private func makeCache(byteLimit: Int = 1_000_000) -> (PlaybackPreloadCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (PlaybackPreloadCache(directory: directory, byteLimit: byteLimit), directory)
    }

    private func makeKey(server: String = "server", account: String = "listener", media: String = "song") -> PlaybackPreloadCache.Key {
        .init(scope: LibraryScope(serverID: server, username: account, deviceID: "device"),
              media: .library(media), quality: .original)
    }

    private func makeStream(length: Int64, read: @escaping @Sendable (ClosedRange<Int64>) async throws -> Data = {
        Data(repeating: 1, count: Int($0.count))
    }) -> PlaybackStream {
        PlaybackStream(contentType: "public.mp3", fileExtension: "mp3", length: length, quality: .original,
                       availableQualities: [.original], read: read)
    }
}

private actor ReadGate {
    private var reading: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            reading = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilReading() async {
        guard reading == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        reading?.resume()
        reading = nil
    }
}
