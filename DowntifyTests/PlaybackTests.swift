import AVFoundation
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Downtify

final class PlaybackTests: XCTestCase {
    func testQueueKeepsDuplicateTracksDistinctAndRestoresTheSelectedOccurrence() throws {
        let first = track("first")
        let second = track("second")
        var queue = PlaybackQueue()
        queue.replace([first, second, first], startingAt: 2)
        let selected = try XCTUnwrap(queue.currentID)
        XCTAssertNotEqual(queue.entries.first?.id, selected)

        queue.move(selected, to: 1)
        queue.setShuffle(true)
        queue.append([track("later")])
        queue.repeatMode = .one
        XCTAssertEqual(queue.next(automatic: true), selected)
        XCTAssertNotEqual(queue.next(automatic: false), selected)
        let saved = queue.saved(position: 22.5)

        var restored = PlaybackQueue()
        XCTAssertEqual(restored.restore(saved, tracks: [first, track("later")]), 22.5)
        XCTAssertEqual(restored.currentID, selected)
        XCTAssertEqual(restored.order.map(\.id), queue.order.filter { $0.track.id != second.id }.map(\.id))
        XCTAssertEqual(restored.repeatMode, .one)
        let following = restored.next(automatic: false)
        restored.remove(selected)
        XCTAssertEqual(restored.currentID, following)
        restored.setShuffle(false)
        XCTAssertEqual(restored.order, restored.entries)
    }

    func testRepeatAllWrapsAndMissingRestorationItemStartsAtZero() throws {
        let first = track("first")
        var queue = PlaybackQueue()
        queue.replace([first, track("last")], startingAt: 1)
        let saved = queue.saved(position: 45)
        XCTAssertNil(queue.next(automatic: true))
        queue.repeatMode = .all
        XCTAssertEqual(queue.next(automatic: true), queue.entries.first?.id)

        var restored = PlaybackQueue()
        XCTAssertEqual(restored.restore(saved, tracks: [first]), 0)
        XCTAssertEqual(restored.current?.track, first)
    }

    func testQueueMovesDuplicateOccurrenceToFinalIndexAndKeepsCurrentID() throws {
        let repeated = track("same")
        var queue = PlaybackQueue()
        queue.replace([track("first"), repeated, track("middle"), repeated], startingAt: 0)
        let firstOccurrence = queue.entries[1].id
        let middle = queue.entries[2].id
        let secondOccurrence = queue.entries[3].id
        let selected = try XCTUnwrap(queue.currentID)

        queue.move(secondOccurrence, to: 1)
        XCTAssertEqual(queue.order.map(\.id), [selected, secondOccurrence, firstOccurrence, middle])
        queue.move(firstOccurrence, to: queue.entries.count - 1)
        XCTAssertEqual(queue.order.last?.id, firstOccurrence)
        XCTAssertEqual(queue.currentID, selected)

        let beforeInvalidMove = queue.order.map(\.id)
        queue.move(secondOccurrence, to: queue.entries.count)
        XCTAssertEqual(queue.order.map(\.id), beforeInvalidMove)
    }

    func testQualityChoicesIntersectRuntimeAndAdvertisedCapabilities() throws {
        let server = try serverInfo(formats: ["opus", "aac", "mp3"], bitrates: [96, 128, 256])
        XCTAssertEqual(PlaybackQualities.available(on: server, supportsOggOpus: true), [
            .original, .transcoded(.opus, bitrate: 96), .transcoded(.opus, bitrate: 128),
            .transcoded(.opus, bitrate: 256), .transcoded(.aac, bitrate: 128),
            .transcoded(.aac, bitrate: 256), .transcoded(.mp3, bitrate: 128)
        ])
        XCTAssertEqual(PlaybackQualities.available(on: server, supportsOggOpus: false), [
            .original, .transcoded(.aac, bitrate: 128), .transcoded(.aac, bitrate: 256), .transcoded(.mp3, bitrate: 128)
        ])
        let disabled = try serverInfo(formats: [], bitrates: [], available: false)
        XCTAssertEqual(PlaybackQualities.available(on: disabled, supportsOggOpus: true), [.original])
    }

    func testStreamUsesVerifiedBasePathBearerHeaderRangesAndValidator() async throws {
        let transport = StreamTestTransport([
            .info(), .range("0-1/8", bytes: [1, 2]), .range("3-5/8", bytes: [4, 5, 6])
        ])
        let stream = try await PlaybackStreamResolver(transport: transport).resolve(
            track: track("song"), quality: .transcoded(.aac, bitrate: 128), session: deviceSession()
        )
        XCTAssertEqual(stream.length, 8)
        XCTAssertEqual(stream.fileExtension, "m4a")
        XCTAssertEqual(stream.quality, .transcoded(.aac, bitrate: 128))
        let bytes = try await stream.read(3...5)
        XCTAssertEqual(bytes, Data([4, 5, 6]))

        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/music/api/server/info")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].url?.absoluteString, "https://music.local/music/api/v1/tracks/song/stream?format=aac&bitrate=128")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer playback-test-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Range"), "bytes=3-5")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-Range"), "\"file-v1\"")
    }

    func testOriginalFallbackAndRangeMismatch() async throws {
        let transport = StreamTestTransport([
            .info(), .range("0-1/8", bytes: [1, 2], mime: "audio/mpeg", original: true),
            .range("0-1/8", bytes: [1, 2], mime: "audio/mpeg")
        ])
        let stream = try await PlaybackStreamResolver(transport: transport).resolve(
            track: track("song"), quality: .transcoded(.aac, bitrate: 128), session: deviceSession()
        )
        XCTAssertEqual(stream.quality, .original)
        XCTAssertEqual(stream.fileExtension, "mp3")
        do {
            _ = try await stream.read(2...3)
            XCTFail("Expected rejection of bytes returned at the wrong offset")
        } catch {
            XCTAssertEqual(error as? PlaybackFailure, .invalidStream)
        }
    }

    func testSessionVerificationAndHTTPConsentPreventCredentialTransmission() async throws {
        let changed = StreamTestTransport([.info(id: "other")])
        do {
            _ = try await PlaybackStreamResolver(transport: changed).resolve(
                track: track("song"), quality: .original, session: deviceSession()
            )
            XCTFail("Expected a server identity failure")
        } catch {
            XCTAssertEqual(error as? PlaybackFailure, .differentServer)
        }
        let checked = await changed.requests
        XCTAssertEqual(checked.count, 1)
        XCTAssertNil(checked.first?.value(forHTTPHeaderField: "Authorization"))

        let insecure = StreamTestTransport([])
        do {
            _ = try await PlaybackStreamResolver(transport: insecure).resolve(
                track: track("song"), quality: .original, session: deviceSession(base: "http://music.local")
            )
            XCTFail("Expected an HTTP consent failure")
        } catch {
            XCTAssertEqual(error as? PlaybackFailure, .insecureAddress)
        }
        let blocked = await insecure.requests
        XCTAssertTrue(blocked.isEmpty)
    }

    @MainActor
    func testControllerRestoresPausedAndClearsPlaybackOnSignOut() async throws {
        let fixture = PlaybackFixture()
        let session = deviceSession()
        let first = track("first")
        let second = track("second")
        await fixture.controller.updateSession(session) { [first, second] }
        fixture.controller.replaceQueue([first, second], startingAt: 1, autoplay: false)
        fixture.controller.seek(to: 48)
        let entryID = fixture.controller.queue.currentID
        fixture.controller.setRepeat(.all)

        let restarted = PlaybackFixture(store: fixture.store)
        await restarted.controller.updateSession(session) { [first, second] }
        XCTAssertEqual(restarted.controller.queue.currentID, entryID)
        XCTAssertEqual(restarted.controller.queue.current?.track, second)
        XCTAssertEqual(restarted.controller.queue.repeatMode, .all)
        XCTAssertEqual(restarted.controller.position, 48)
        XCTAssertEqual(restarted.controller.phase, .paused)
        XCTAssertTrue(restarted.engine.loads.isEmpty)

        let play = expectation(description: "Restored item starts")
        restarted.engine.onPlay = { play.fulfill() }
        restarted.remote.onCommand?(.play)
        await fulfillment(of: [play], timeout: 3)
        XCTAssertEqual(restarted.engine.loads, [48])
        XCTAssertEqual(restarted.remote.metadata?.track, second)
        await restarted.controller.updateSession(nil) { [] }
        XCTAssertEqual(restarted.controller.phase, .idle)
        XCTAssertNil(restarted.remote.metadata)
        XCTAssertFalse(restarted.audio.active)
        XCTAssertEqual(restarted.store.load(for: scope)?.position, 48)
    }

    @MainActor
    func testNetworkQualityChangeResumesAtSamePositionAndInterruptionHonorsPause() async throws {
        let fixture = PlaybackFixture()
        await fixture.controller.updateSession(deviceSession()) { [] }
        let starts = expectation(description: "Initial playback")
        fixture.engine.onPlay = { starts.fulfill() }
        fixture.controller.replaceQueue([track("song")])
        await fulfillment(of: [starts], timeout: 3)
        fixture.engine.onEvent?(.position(23, duration: 100))
        XCTAssertEqual(fixture.controller.phase, .playing)
        XCTAssertTrue(fixture.audio.active)

        let resumes = expectation(description: "Replaced stream starts")
        fixture.engine.onPlay = { resumes.fulfill() }
        fixture.network.update?(.cellular)
        await fulfillment(of: [resumes], timeout: 3)
        let requests = await fixture.resolver.qualities
        XCTAssertEqual(requests, [.original, fixture.controller.qualityPreferences.cellular])
        XCTAssertEqual(fixture.engine.loads, [0, 23])

        fixture.audio.onEvent?(.interruptionBegan)
        XCTAssertEqual(fixture.controller.phase, .paused)
        fixture.engine.onPlay = nil
        fixture.audio.onEvent?(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(fixture.controller.phase, .playing)

        fixture.audio.onEvent?(.interruptionBegan)
        fixture.remote.onCommand?(.pause)
        fixture.audio.onEvent?(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(fixture.controller.phase, .paused)
        XCTAssertFalse(fixture.audio.active)
        fixture.audio.onEvent?(.mediaServicesReset)
        XCTAssertEqual(fixture.engine.mediaResets, 1)
    }

    @MainActor
    func testRemoteSeekAndEndOfTrackAdvance() async throws {
        let fixture = PlaybackFixture()
        await fixture.controller.updateSession(deviceSession()) { [] }
        let starts = expectation(description: "First track starts")
        fixture.engine.onPlay = { starts.fulfill() }
        fixture.controller.replaceQueue([track("first"), track("second")])
        await fulfillment(of: [starts], timeout: 3)

        fixture.remote.onCommand?(.seek(10))
        XCTAssertEqual(fixture.engine.seeks, [10])
        XCTAssertEqual(fixture.remote.metadata?.position, 10)
        let advances = expectation(description: "Next track starts")
        fixture.engine.onPlay = { advances.fulfill() }
        fixture.engine.onEvent?(.ended)
        await fulfillment(of: [advances], timeout: 3)
        XCTAssertEqual(fixture.controller.queue.current?.track.id, "second")
        fixture.engine.onEvent?(.ended)
        XCTAssertEqual(fixture.controller.phase, .ended)
        XCTAssertFalse(fixture.audio.active)
        XCTAssertEqual(fixture.remote.metadata?.position, 100)
    }

    @MainActor
    func testAVPlayerLoadsAndSeeksRangedWAV() async throws {
        let wave = waveFixture()
        let engine = AVPlaybackEngine()
        defer { engine.reset() }
        let ranges = ReadRanges()
        let stream = PlaybackStream(contentType: "com.microsoft.waveform-audio", fileExtension: "wav",
                                    length: Int64(wave.count), quality: .original, availableQualities: [.original]) { range in
            await ranges.record(range)
            return wave.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
        }
        let opened = expectation(description: "AVPlayer loaded and sought the ranged asset")
        let task = Task {
            defer { opened.fulfill() }
            try await engine.load(stream, at: 0.25)
        }
        await fulfillment(of: [opened], timeout: 5)
        task.cancel()
        // Reset also finishes pending resource requests if the load timed out.
        engine.reset()
        try await task.value
        let requested = await ranges.values
        XCTAssertFalse(requested.isEmpty)
        XCTAssertTrue(requested.allSatisfy { $0.upperBound < wave.count })
    }

    @MainActor
    func testAVPlayerOpusWhenTheRuntimeAdvertisesOggSupport() async throws {
        try XCTSkipUnless(PlaybackCodec.supportsOggOpus, "This AVFoundation runtime does not advertise Ogg Opus support")
        // Generated silence, Ogg Opus at 48 kHz.
        let opus = try XCTUnwrap(Data(base64Encoded: "T2dnUwACAAAAAAAAAADR2ZHNAAAAAIo2FzIBE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAAAAAAANHZkc0BAAAAi6GH9gE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAyAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMiBsaWJvcHVzT2dnUwAEeDkAAAAAAADR2ZHNAgAAAKroyToQAwMDAwMDAwMDAwMDAwMDA/j//vj//vj//vj//vj//vj//vj//vj//vj//vj//vj//vj//vj//vj//vj//vj//g=="))
        let type = try XCTUnwrap(UTType(filenameExtension: "ogg"))
        let stream = PlaybackStream(contentType: type.identifier, fileExtension: "ogg",
                                    length: Int64(opus.count), quality: .original, availableQualities: [.original]) { range in
            opus.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
        }
        let engine = AVPlaybackEngine()
        defer { engine.reset() }
        try await engine.load(stream, at: 0)
    }

    @MainActor
    func testAudioSessionTranslatesInterruptionsAndDisconnectedOutputs() {
        let notifications = NotificationCenter()
        let system = AVAudioSession.sharedInstance()
        let audio = SystemPlaybackAudioSession(session: system, notifications: notifications)
        var events: [String] = []
        audio.onEvent = { event in
            switch event {
            case .interruptionBegan: events.append("began")
            case .interruptionEnded(shouldResume: true): events.append("resume")
            case .outputDisconnected: events.append("disconnected")
            default: XCTFail("Unexpected audio event")
            }
        }
        notifications.post(name: AVAudioSession.interruptionNotification, object: system, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
        notifications.post(name: AVAudioSession.interruptionNotification, object: system, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ])
        notifications.post(name: AVAudioSession.routeChangeNotification, object: system, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        ])
        XCTAssertEqual(events, ["began", "resume", "disconnected"])
    }

    private var scope: LibraryScope { LibraryScope(serverID: "server", username: "listener", deviceID: "device") }

    private func track(_ id: String) -> LibraryTrack {
        LibraryTrack(id: id, file: "\(id).mp3", title: id, artist: "Artist", artists: ["Artist"], album: "Album",
                     albumArtist: "Artist", albumID: "album", artistID: "artist", trackNumber: 1, year: "2026",
                     duration: 100, codec: "mp3", bitrate: 128_000, sampleRate: 44_100, channels: 2, size: 100,
                     added: 0, hasCover: false, isExplicit: false, playlists: [])
    }

    private func deviceSession(base: String = "https://music.local/music") -> DeviceSession {
        DeviceSession(baseAddress: base, serverID: "server", serverName: "Music", deviceID: "device",
                      username: "listener", role: nil, token: "playback-test-token", allowsInsecureHTTP: false)
    }

    private func serverInfo(formats: [String], bitrates: [Int], available: Bool = true) throws -> MobileAPIV1.ServerInfoDTO {
        let body: [String: Any] = [
            "product": "Downtify", "api_version": 1, "server_id": "server",
            "capabilities": ["transcoding": ["available": available, "formats": formats, "bitrates": bitrates]]
        ]
        return try JSONDecoder().decode(MobileAPIV1.ServerInfoDTO.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func waveFixture() -> Data {
        let samples = Data(repeating: 0, count: 16_000)
        var wave = Data()
        func write(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) } }
        func writeShort(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) } }
        wave.append(contentsOf: "RIFF".utf8)
        write(UInt32(samples.count + 36))
        wave.append(contentsOf: "WAVEfmt ".utf8)
        write(16)
        writeShort(1)
        writeShort(1)
        write(8_000)
        write(16_000)
        writeShort(2)
        writeShort(16)
        wave.append(contentsOf: "data".utf8)
        write(UInt32(samples.count))
        wave.append(samples)
        return wave
    }
}

private actor ReadRanges {
    private(set) var values: [ClosedRange<Int64>] = []
    func record(_ range: ClosedRange<Int64>) { values.append(range) }
}

private actor StreamTestTransport: HTTPDataLoading {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func info(id: String = "server") -> Self {
            Response(status: 200, headers: ["Content-Type": "application/json"],
                     body: Data("""
                       {"product":"Downtify","api_version":1,"server_id":"\(id)",
                        "capabilities":{"transcoding":{"available":true,"formats":["aac"],"bitrates":[128]}}}
                       """.utf8))
        }

        static func range(_ range: String, bytes: [UInt8], mime: String = "audio/mp4", original: Bool = false) -> Self {
            Response(status: 206,
                     headers: ["Content-Range": "bytes \(range)", "Content-Type": mime, "ETag": "\"file-v1\"",
                               "X-Downtify-Transcoded": original ? "no" : "aac/128"], body: Data(bytes))
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty, let url = request.url else { throw APIError.invalidResponse }
        let result = responses.removeFirst()
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil,
                                                     headerFields: result.headers))
        return (result.body, response)
    }
}

@MainActor
private struct PlaybackFixture {
    let engine = TestPlaybackEngine()
    let audio = TestAudioSession()
    let network = TestNetworkMonitor()
    let remote = TestRemoteControls()
    let resolver = TestStreamResolver()
    let store: TestPlaybackStore
    let controller: PlaybackController

    init(store: TestPlaybackStore? = nil) {
        self.store = store ?? TestPlaybackStore()
        controller = PlaybackController(engine: engine, resolver: resolver, audioSession: audio, remote: remote,
                                        store: self.store, networkMonitor: network, verifySession: { _ in })
    }
}

@MainActor
private final class TestPlaybackEngine: PlaybackEngining {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var onPlay: (() -> Void)?
    var loads: [TimeInterval] = []
    var seeks: [TimeInterval] = []
    var mediaResets = 0

    func load(_ stream: PlaybackStream, at position: TimeInterval) async throws { loads.append(position) }
    func play() {
        onEvent?(.playing)
        onPlay?()
    }
    func pause() {}
    func seek(to position: TimeInterval) { seeks.append(position) }
    func reset() {}
    func resetMediaServices() { mediaResets += 1 }
}

private actor TestStreamResolver: PlaybackStreamResolving {
    var qualities: [PlaybackQuality] = []

    func resolve(track: LibraryTrack, quality: PlaybackQuality, session: DeviceSession) async throws -> PlaybackStream {
        qualities.append(quality)
        return PlaybackStream(contentType: "public.mp3", fileExtension: "mp3", length: 8, quality: quality,
                              availableQualities: [.original, quality], read: { _ in Data() })
    }
}

@MainActor
private final class TestAudioSession: PlaybackAudioSession {
    var onEvent: ((PlaybackAudioEvent) -> Void)?
    var active = false
    func activate() throws { active = true }
    func deactivate() { active = false }
}

@MainActor
private final class TestNetworkMonitor: PlaybackNetworkMonitoring {
    var update: (@MainActor (PlaybackNetwork) -> Void)?
    func start(_ update: @escaping @MainActor (PlaybackNetwork) -> Void) { self.update = update }
}

@MainActor
private final class TestRemoteControls: PlaybackRemoteControlling {
    var onCommand: ((PlaybackRemoteCommand) -> Void)?
    var metadata: PlaybackMetadata?
    func publish(_ metadata: PlaybackMetadata?) { self.metadata = metadata }
}

@MainActor
private final class TestPlaybackStore: PlaybackStateStoring {
    private var queues: [(LibraryScope, SavedPlaybackQueue)] = []
    private var qualities = PlaybackQualities()

    func load(for scope: LibraryScope) -> SavedPlaybackQueue? { queues.first { $0.0 == scope }?.1 }
    func save(_ queue: SavedPlaybackQueue, for scope: LibraryScope) {
        queues.removeAll { $0.0 == scope }
        queues.append((scope, queue))
    }
    func loadQualities() -> PlaybackQualities { qualities }
    func saveQualities(_ qualities: PlaybackQualities) { self.qualities = qualities }
}
