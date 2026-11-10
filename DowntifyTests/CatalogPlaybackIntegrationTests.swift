import Foundation
import XCTest
@testable import Downtify

final class CatalogPlaybackIntegrationTests: XCTestCase {
    func testMixedQueueMetadataAndUpcomingItemsNeverAssumeLibraryTrack() throws {
        let library = track("local")
        let provider = try catalogSong()
        var queue = PlaybackQueue()
        queue.replace([.library(library), .catalog(provider), .library(track("later"))], startingAt: 0)
        queue.repeatMode = .off
        let buffering = PlaybackBuffering(readAhead: 2, cacheMegabytes: 100, readAheadOnCellular: false)

        XCTAssertEqual(buffering.upcomingItems(in: queue, on: .wifiOrWired), [.catalog(provider), .library(track("later"))])
        XCTAssertEqual(queue.current?.item.libraryTrack, library)
        XCTAssertNil(queue.entries[1].item.libraryTrack)
        XCTAssertEqual(queue.entries[1].item.title, "Provider song")
        XCTAssertEqual(queue.entries[1].item.artist, "Provider artist")
        XCTAssertEqual(queue.entries[1].item.album, "Provider album")
    }

    func testLibraryOnlyPruningPreservesCurrentEntryAndQueueOrder() throws {
        let local = track("local")
        let external = try catalogSong()
        var queue = PlaybackQueue()
        queue.replace([.library(local), .catalog(external), .library(track("after"))], startingAt: 0)
        let currentID = queue.currentID

        queue.applyLibraryOnlyPolicy(true, tracks: [local])

        XCTAssertEqual(queue.currentID, currentID)
        XCTAssertEqual(queue.entries.map(\.item.libraryTrack?.id), ["local", "after"])
    }

    private func catalogSong() throws -> CatalogSong {
        let json = #"{"source":"youtube","song_id":"provider-1","name":"Provider song","artist":"Provider artist","artists":["Provider artist"],"album_name":"Provider album","duration":180,"url":"https://youtube.test/watch?v=provider-1"}"#
        return try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
    }

    private func track(_ id: String) -> LibraryTrack {
        LibraryTrack(id: id, file: "\(id).mp3", title: id, artist: "Artist", artists: ["Artist"], album: "Album",
                     albumArtist: "Artist", albumID: "album", artistID: "artist", trackNumber: 1, year: "2026",
                     duration: 100, codec: "mp3", bitrate: 128_000, sampleRate: 44_100, channels: 2, size: 100,
                     added: 0, hasCover: false, isExplicit: false, playlists: [])
    }
}

@MainActor
extension CatalogPlaybackIntegrationTests {
    func testControllerStopsAfterThreeConsecutiveUnplayableCatalogItems() async throws {
        let controller = PlaybackController(
            engine: CatalogTestEngine(), resolver: CatalogFailingResolver(), audioSession: CatalogTestAudio(),
            remote: CatalogTestRemote(), store: CatalogTestStore(), networkMonitor: CatalogTestNetwork(),
            verifySession: { _ in }
        )
        await controller.updateSession(catalogSession(), tracks: { [] })
        let songs = try (1...4).map { index in try catalogSong("Provider song \(index)", id: "provider-\(index)") }
        controller.replaceQueue(songs.map(PlaybackItem.catalog))

        for _ in 0..<100 where controller.phase != .failed(.invalidStream) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(controller.phase, .failed(.invalidStream))
        XCTAssertEqual(controller.queue.current?.item.catalogSong?.title, "Provider song 3")
        XCTAssertEqual(controller.queue.entries.count, 4)
    }

    func testAsynchronousEngineCatalogFailuresSkipAndStopAfterThree() async throws {
        let engine = CatalogTestEngine(emitsPlaying: false)
        let controller = PlaybackController(
            engine: engine, resolver: CatalogPlayableResolver(), audioSession: CatalogTestAudio(),
            remote: CatalogTestRemote(), store: CatalogTestStore(), networkMonitor: CatalogTestNetwork(),
            verifySession: { _ in }
        )
        await controller.updateSession(catalogSession(), tracks: { [] })
        let songs = try (1...4).map { index in try catalogSong("Async song \(index)", id: "async-\(index)") }
        controller.replaceQueue(songs.map(PlaybackItem.catalog))

        for failureIndex in 1...3 {
            for _ in 0..<100 where engine.playCount < failureIndex {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(engine.playCount, failureIndex)
            engine.emit(.failed(.invalidStream))
        }

        XCTAssertEqual(controller.phase, .failed(.invalidStream))
        XCTAssertEqual(controller.queue.current?.item.catalogSong?.title, "Async song 3")
        XCTAssertEqual(engine.loadCount, 3)
    }

    func testUnauthorizedCatalogLoadVerifiesSessionWithoutAdvancingQueue() async throws {
        let counter = CatalogVerifyCounter()
        let verifiedController = PlaybackController(
            engine: CatalogTestEngine(), resolver: CatalogUnauthorizedResolver(), audioSession: CatalogTestAudio(),
            remote: CatalogTestRemote(), store: CatalogTestStore(), networkMonitor: CatalogTestNetwork(),
            verifySession: { _ in await counter.increment() }
        )
        await verifiedController.updateSession(catalogSession(), tracks: { [] })
        let songs = try (1...2).map { index in try catalogSong("Unauthorized \(index)", id: "unauthorized-\(index)") }
        verifiedController.replaceQueue(songs.map(PlaybackItem.catalog))
        let firstID = verifiedController.queue.currentID

        for _ in 0..<100 {
            if await counter.value > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let verificationCount = await counter.value

        XCTAssertEqual(verifiedController.phase, .failed(.unauthorized))
        XCTAssertEqual(verifiedController.queue.currentID, firstID)
        XCTAssertEqual(verificationCount, 1)
    }

    private func catalogSong(_ title: String, id: String) throws -> CatalogSong {
        let json = #"{"source":"youtube","song_id":"\#(id)","name":"\#(title)","artist":"Provider artist","artists":["Provider artist"],"album_name":"Provider album","duration":180,"url":"https://youtube.test/watch?v=\#(id)"}"#
        return try JSONDecoder().decode(CatalogSong.self, from: Data(json.utf8))
    }

    private func catalogSession() -> DeviceSession {
        DeviceSession(baseAddress: "https://music.local/music", serverID: "server", serverName: "Music",
                      deviceID: "device", username: "listener", role: nil, token: "token", allowsInsecureHTTP: false)
    }
}

@MainActor
private final class CatalogTestEngine: PlaybackEngining {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private(set) var loadCount = 0
    private(set) var playCount = 0
    private let emitsPlaying: Bool
    init(emitsPlaying: Bool = true) { self.emitsPlaying = emitsPlaying }
    func load(_ stream: PlaybackStream, at position: TimeInterval) async throws { loadCount += 1 }
    func play() { playCount += 1; if emitsPlaying { onEvent?(.playing) } }
    func emit(_ event: PlaybackEngineEvent) { onEvent?(event) }
    func pause() {}
    func seek(to position: TimeInterval) {}
    func reset() {}
    func resetMediaServices() {}
}

private struct CatalogFailingResolver: PlaybackStreamResolving {
    func resolve(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        throw PlaybackFailure.invalidStream
    }
    func resolve(catalogSong: CatalogSong, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        throw PlaybackFailure.invalidStream
    }
}

@MainActor
private final class CatalogTestAudio: PlaybackAudioSession {
    var onEvent: ((PlaybackAudioEvent) -> Void)?
    func activate() throws {}
    func deactivate() {}
}

@MainActor
private final class CatalogTestRemote: PlaybackRemoteControlling {
    var onCommand: ((PlaybackRemoteCommand) -> Void)?
    func publish(_ metadata: PlaybackMetadata?) {}
}

@MainActor
private struct CatalogTestStore: PlaybackStateStoring {
    func load(for scope: LibraryScope) -> SavedPlaybackQueue? { nil }
    func save(_ queue: SavedPlaybackQueue, for scope: LibraryScope) {}
    func loadQualities() -> PlaybackQualities { PlaybackQualities() }
    func saveQualities(_ qualities: PlaybackQualities) {}
}

@MainActor
private final class CatalogTestNetwork: PlaybackNetworkMonitoring {
    func start(_ update: @escaping @MainActor (PlaybackNetwork) -> Void) { update(.wifiOrWired) }
}

private struct CatalogPlayableResolver: PlaybackStreamResolving {
    func resolve(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        playableStream()
    }
    func resolve(catalogSong: CatalogSong, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        playableStream()
    }
    private func playableStream() -> PlaybackStream {
        PlaybackStream(contentType: "public.mp3", fileExtension: "mp3", length: 10,
                       quality: .original, availableQualities: [.original]) { _ in Data(repeating: 0, count: 10) }
    }
}

private struct CatalogUnauthorizedResolver: PlaybackStreamResolving {
    func resolve(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        throw PlaybackFailure.unauthorized
    }
    func resolve(catalogSong: CatalogSong, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        throw PlaybackFailure.unauthorized
    }
}

private actor CatalogVerifyCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
