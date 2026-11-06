import Combine
import Foundation

enum PlaybackPhase: Equatable {
    case idle, loading, paused, playing, buffering, ended
    case failed(PlaybackFailure)
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var network: PlaybackNetwork = .wifiOrWired
    @Published private(set) var qualityPreferences: PlaybackQualities
    @Published private(set) var availableQualities: [PlaybackQuality] = [.original]
    @Published private(set) var streamQuality: PlaybackQuality?

    private let engine: any PlaybackEngining
    private let resolver: any PlaybackStreamResolving
    private let audioSession: any PlaybackAudioSession
    private let remote: any PlaybackRemoteControlling
    private let store: any PlaybackStateStoring
    private let networkMonitor: any PlaybackNetworkMonitoring
    private let verifySession: (DeviceSession) async -> Void

    private var session: DeviceSession?
    private var loaded = false
    private var wantsPlayback = false
    private var isInterrupted = false
    private var resumeAfterInterruption = false
    private var resumeAfterNetworkFailure = false
    private var lastConnectedNetwork: PlaybackNetwork = .wifiOrWired
    private var queueReadyForPersistence = false
    private var lastSavedPosition: TimeInterval = 0
    private var sessionTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(engine: any PlaybackEngining, resolver: any PlaybackStreamResolving,
         audioSession: any PlaybackAudioSession, remote: any PlaybackRemoteControlling,
         store: any PlaybackStateStoring, networkMonitor: any PlaybackNetworkMonitoring,
         verifySession: @escaping (DeviceSession) async -> Void) {
        self.engine = engine
        self.resolver = resolver
        self.audioSession = audioSession
        self.remote = remote
        self.store = store
        self.networkMonitor = networkMonitor
        self.verifySession = verifySession
        qualityPreferences = store.loadQualities()

        engine.onEvent = { [weak self] event in self?.receive(event) }
        audioSession.onEvent = { [weak self] event in self?.receive(event) }
        remote.onCommand = { [weak self] command in self?.receive(command) }
        networkMonitor.start { [weak self] path in self?.networkChanged(path) }
    }

    deinit {
        sessionTask?.cancel()
        loadTask?.cancel()
    }

    func observeSessions(
        updates: @escaping () async throws -> AsyncStream<DeviceSession?>,
        tracks: @escaping () async throws -> [LibraryTrack]
    ) {
        guard sessionTask == nil else { return }
        sessionTask = Task { [weak self] in
            defer { self?.sessionTask = nil }
            guard let sessions = try? await updates() else { return }
            for await session in sessions {
                guard !Task.isCancelled else { return }
                await self?.updateSession(session, tracks: tracks)
            }
        }
    }

    func updateSession(_ newSession: DeviceSession?, tracks: () async throws -> [LibraryTrack]) async {
        guard session != newSession else { return }
        persist()
        stopEngine()
        audioSession.deactivate()
        session = newSession
        wantsPlayback = false
        resumeAfterInterruption = false
        resumeAfterNetworkFailure = false
        queueReadyForPersistence = false
        availableQualities = [.original]
        queue = PlaybackQueue()
        position = 0
        duration = nil
        phase = .idle
        publishMetadata()

        guard let scope, let saved = store.load(for: scope) else { return }
        guard let tracks = try? await tracks(), !Task.isCancelled, session == newSession,
              !queueReadyForPersistence else { return }
        position = queue.restore(saved, tracks: tracks)
        queueReadyForPersistence = true
        duration = knownDuration(queue.current?.track)
        position = boundedPosition(position)
        if queue.current != nil {
            phase = duration.map { position >= $0 } == true ? .ended : .paused
        }
        publishMetadata()
    }

    func replaceQueue(_ tracks: [LibraryTrack], startingAt index: Int = 0, autoplay: Bool = true) {
        queue.replace(tracks, startingAt: index)
        didSelect(autoplay: autoplay)
    }

    func append(_ tracks: [LibraryTrack]) {
        guard !tracks.isEmpty else { return }
        let hadCurrent = queue.current != nil
        queue.append(tracks)
        if hadCurrent {
            didEditQueue()
        } else {
            didSelect(autoplay: false)
        }
    }

    func remove(_ id: UUID) {
        let wasCurrent = queue.currentID == id
        queue.remove(id)
        if wasCurrent {
            didSelect(autoplay: wantsPlayback)
        } else {
            didEditQueue()
        }
    }

    func move(_ id: UUID, to index: Int) {
        queue.move(id, to: index)
        didEditQueue()
    }

    func select(_ id: UUID) {
        guard queue.entries.contains(where: { $0.id == id }) else { return }
        if queue.currentID == id { play(); return }
        queue.select(id)
        didSelect(autoplay: true)
    }

    func setRepeat(_ mode: PlaybackRepeat) {
        queue.repeatMode = mode
        didEditQueue()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        didEditQueue()
    }

    func setQualities(_ qualities: PlaybackQualities) {
        let old = preferredQuality
        qualityPreferences = qualities
        store.saveQualities(qualities)
        if old != preferredQuality { reloadForQualityChange() }
    }

    func play() {
        guard queue.current != nil, !wantsPlayback else { return }
        resumeAfterNetworkFailure = false
        if isInterrupted {
            resumeAfterInterruption = true
            return
        }
        wantsPlayback = true
        if phase == .ended { seek(to: 0) }
        if loaded {
            startEngine()
        } else {
            loadCurrent()
        }
    }

    func pause() {
        wantsPlayback = false
        resumeAfterInterruption = false
        resumeAfterNetworkFailure = false
        if phase == .loading { stopEngine() }
        engine.pause()
        audioSession.deactivate()
        if queue.current != nil { phase = .paused }
        didEditQueue()
    }

    func togglePlayback() {
        if wantsPlayback || resumeAfterInterruption { pause() } else { play() }
    }

    func seek(to seconds: TimeInterval) {
        guard queue.current != nil, seconds.isFinite else { return }
        position = boundedPosition(seconds)
        if phase == .ended { phase = .paused }
        if loaded { engine.seek(to: position) }
        didEditQueue()
    }

    func skipNext() {
        guard let next = queue.next(automatic: false) else { return }
        advance(to: next)
    }

    func skipPrevious() {
        guard queue.current != nil else { return }
        if position >= 3 || queue.previous() == nil {
            seek(to: 0)
        } else if let previous = queue.previous() {
            advance(to: previous)
        }
    }

    func persist() {
        guard queueReadyForPersistence, let scope else { return }
        store.save(queue.saved(position: position), for: scope)
        lastSavedPosition = position
    }

    private var scope: LibraryScope? {
        session.map { LibraryScope(serverID: $0.serverID, username: $0.username, deviceID: $0.deviceID) }
    }

    private var preferredQuality: PlaybackQuality { qualityPreferences.preferred(on: lastConnectedNetwork) }

    private func didEditQueue() {
        queueReadyForPersistence = true
        persist()
        publishMetadata()
    }

    private func didSelect(autoplay: Bool) {
        stopEngine()
        if !autoplay || queue.current == nil { audioSession.deactivate() }
        wantsPlayback = false
        resumeAfterInterruption = false
        resumeAfterNetworkFailure = false
        position = 0
        duration = knownDuration(queue.current?.track)
        phase = queue.current == nil ? .idle : .paused
        didEditQueue()
        if autoplay { play() }
    }

    private func advance(to id: UUID) {
        if queue.currentID == id {
            seek(to: 0)
            return
        }
        queue.select(id)
        didSelect(autoplay: wantsPlayback)
    }

    private func loadCurrent() {
        guard let track = queue.current?.track else { return }
        guard let session else { fail(.signedOut); return }
        stopEngine()
        let generation = loadGeneration
        let quality = preferredQuality
        phase = .loading
        publishMetadata()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await resolver.resolve(track: track, quality: quality, session: session)
                try requireCurrentLoad(generation)
                availableQualities = stream.availableQualities
                streamQuality = stream.quality
                let initial = position
                try await engine.load(stream, at: initial)
                try requireCurrentLoad(generation)
                loaded = true
                if position != initial { engine.seek(to: position) }
                if wantsPlayback {
                    startEngine()
                } else {
                    phase = .paused
                    publishMetadata()
                }
            } catch is CancellationError {
                return
            } catch {
                guard loadGeneration == generation, !Task.isCancelled else { return }
                fail(.from(error))
            }
        }
    }

    private func requireCurrentLoad(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
    }

    private func startEngine() {
        do {
            try audioSession.activate()
        } catch {
            fail(.audioSession)
            return
        }
        phase = .buffering
        publishMetadata()
        engine.play()
    }

    private func stopEngine() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        loaded = false
        streamQuality = nil
        engine.reset()
    }

    private func fail(_ failure: PlaybackFailure) {
        resumeAfterNetworkFailure = failure == .network && wantsPlayback
        wantsPlayback = false
        stopEngine()
        audioSession.deactivate()
        phase = .failed(failure)
        persist()
        publishMetadata()
        if failure == .unauthorized, let session {
            Task { await verifySession(session) }
        }
    }

    private func receive(_ event: PlaybackEngineEvent) {
        switch event {
        case .playing:
            guard wantsPlayback, loaded else { return }
            phase = .playing
        case .buffering:
            guard wantsPlayback, loaded else { return }
            phase = .buffering
        case let .position(elapsed, actualDuration):
            guard loaded, elapsed.isFinite else { return }
            if let actualDuration, actualDuration.isFinite, actualDuration > 0 { duration = actualDuration }
            position = boundedPosition(elapsed)
            if abs(position - lastSavedPosition) >= 5 { persist() }
        case .ended:
            guard wantsPlayback, loaded else { return }
            if let next = queue.next(automatic: true) {
                if next == queue.currentID {
                    seek(to: 0)
                    startEngine()
                } else {
                    advance(to: next)
                }
                return
            }
            wantsPlayback = false
            engine.pause()
            audioSession.deactivate()
            phase = .ended
            if let duration { position = duration }
            persist()
        case let .failed(failure):
            fail(failure)
            return
        }
        publishMetadata()
    }

    private func receive(_ event: PlaybackAudioEvent) {
        switch event {
        case .interruptionBegan:
            guard !isInterrupted else { return }
            isInterrupted = true
            let wasPlaying = wantsPlayback
            pause()
            resumeAfterInterruption = wasPlaying
        case let .interruptionEnded(shouldResume):
            isInterrupted = false
            let resume = shouldResume && resumeAfterInterruption
            resumeAfterInterruption = false
            if resume { play() }
        case .outputDisconnected:
            pause()
        case .mediaServicesReset:
            isInterrupted = false
            pause()
            stopEngine()
            engine.resetMediaServices()
        }
    }

    private func receive(_ command: PlaybackRemoteCommand) {
        switch command {
        case .play: play()
        case .pause: pause()
        case .toggle: togglePlayback()
        case .next: skipNext()
        case .previous: skipPrevious()
        case let .seek(position): seek(to: position)
        }
    }

    private func networkChanged(_ path: PlaybackNetwork) {
        let previous = network
        let oldQuality = preferredQuality
        network = path
        guard path != .unavailable else { return }
        lastConnectedNetwork = path
        if resumeAfterNetworkFailure, previous == .unavailable {
            play()
        } else if oldQuality != preferredQuality {
            reloadForQualityChange()
        }
    }

    private func reloadForQualityChange() {
        guard queue.current != nil else { return }
        if wantsPlayback {
            loadCurrent()
        } else if loaded {
            stopEngine()
        }
    }

    private func publishMetadata() {
        let metadata = queue.current.flatMap { entry in
            queue.currentIndex.map { index in
                PlaybackMetadata(track: entry.track, position: position, duration: duration, isPlaying: phase == .playing,
                                 wantsPlayback: wantsPlayback, queueIndex: index, queueCount: queue.entries.count,
                                 canSkipNext: queue.next(automatic: false) != nil,
                                 canSkipPrevious: position > 0 || queue.previous() != nil)
            }
        }
        remote.publish(metadata)
    }

    private func boundedPosition(_ seconds: TimeInterval) -> TimeInterval {
        max(0, min(seconds, duration ?? seconds))
    }

    private func knownDuration(_ track: LibraryTrack?) -> TimeInterval? {
        guard let duration = track?.duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }
}
