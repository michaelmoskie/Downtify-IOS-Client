import AVFoundation
import Foundation

enum PlaybackEngineEvent {
    case playing
    case buffering
    case position(TimeInterval, duration: TimeInterval?)
    case ended
    case failed(PlaybackFailure)
}

@MainActor
protocol PlaybackEngining: AnyObject {
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }
    func load(_ stream: PlaybackStream, at position: TimeInterval) async throws
    func play()
    func pause()
    func seek(to position: TimeInterval)
    func setEqualizer(_ equalizer: PlaybackEqualizer)
    func reset()
    func resetMediaServices()
    func setNormalization(_ normalization: PlaybackNormalization)
    /// Keeps the current song playing on its own while it fades out over `seconds`; the next `load` and
    /// `play` fade in over the same time. Used for crossfade between songs.
    func beginCrossfade(over seconds: TimeInterval)
    /// Stops a song that is still fading out and restores full volume.
    func cancelCrossfade()
}

extension PlaybackEngining {
    func setEqualizer(_ equalizer: PlaybackEqualizer) {}
    func setNormalization(_ normalization: PlaybackNormalization) {}
    func beginCrossfade(over seconds: TimeInterval) {}
    func cancelCrossfade() {}
}

/// Equal-power fade curves: the two songs together keep a steady loudness through the overlap.
enum CrossfadeCurve {
    static func fadeOut(_ progress: Double) -> Float { Float(cos(min(max(progress, 0), 1) * .pi / 2)) }
    static func fadeIn(_ progress: Double) -> Float { Float(sin(min(max(progress, 0), 1) * .pi / 2)) }
}

@MainActor
final class AVPlaybackEngine: PlaybackEngining {
    var onEvent: ((PlaybackEngineEvent) -> Void)?

    private var player = AVPlayer()
    private var loader: AudioRangeLoader?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedEndObserver: NSObjectProtocol?
    private var itemGeneration = 0
    private var seekGeneration = 0
    private var seeking = false
    private var normalization: PlaybackNormalization = .off
    private var normalizationTask: Task<Void, Never>?
    private var measurement: PlaybackLevelMeasurement?
    private var normalizationTrack: AVAssetTrack?
    private var equalizer = PlaybackEqualizer()
    /// Shared with every tap, so moving a band takes effect at once.
    private let equalizerSettings = EqualizerSettings()
    private var currentStream: PlaybackStream?
    /// The previous song while it fades out, with the loader that keeps its stream alive.
    private var outgoing: (player: AVPlayer, loader: AudioRangeLoader?)?
    private var outgoingFade: Task<Void, Never>?
    private var fadeIn: Task<Void, Never>?
    private var pendingFadeIn: TimeInterval = 0

    init() {
        observePlayer()
    }

    private func observePlayer() {
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishPosition() }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.publishStatus() }
        }
    }

    deinit {
        normalizationTask?.cancel()
        outgoingFade?.cancel()
        fadeIn?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedEndObserver { NotificationCenter.default.removeObserver(failedEndObserver) }
    }

    func load(_ stream: PlaybackStream, at position: TimeInterval) async throws {
        reset()
        let generation = itemGeneration
        let asset: AVURLAsset
        if let url = stream.fileURL ?? stream.directURL {
            asset = AVURLAsset(url: url)
        } else {
            var location = URLComponents()
            location.scheme = "downtify-stream"
            location.host = "audio"
            location.path = "/track.\(stream.fileExtension)"
            guard let url = location.url else { throw PlaybackFailure.invalidStream }

            asset = AVURLAsset(url: url)
            let loader = AudioRangeLoader(stream: stream)
            self.loader = loader
            loader.onFailure = { [weak self] failure in
                guard self?.itemGeneration == generation else { return }
                self?.onEvent?(.failed(failure))
            }
            asset.resourceLoader.setDelegate(loader, queue: .main)
        }

        guard try await asset.load(.isPlayable) else { throw PlaybackFailure.unsupportedFormat }
        try ensureCurrent(generation)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observe(item, generation: generation)
        currentStream = stream
        normalizeIfNeeded()
        if position > 0 {
            let target = await boundedPosition(position, asset: asset)
            try ensureCurrent(generation)
            let completed = await player.seek(to: time(target), toleranceBefore: .zero, toleranceAfter: .zero)
            try ensureCurrent(generation)
            guard completed else { throw PlaybackFailure.media }
        }
    }

    func play() {
        fadeIn?.cancel()
        fadeIn = nil
        guard pendingFadeIn > 0 else {
            player.volume = 1
            player.play()
            return
        }
        let seconds = pendingFadeIn
        pendingFadeIn = 0
        let incoming = player
        incoming.volume = 0
        incoming.play()
        fadeIn = Task { [weak self] in
            await Self.ramp(over: seconds) { incoming.volume = CrossfadeCurve.fadeIn($0) }
            guard !Task.isCancelled else { return }
            incoming.volume = 1
            self?.fadeIn = nil
        }
    }

    func pause() {
        cancelCrossfade()
        player.pause()
    }

    func beginCrossfade(over seconds: TimeInterval) {
        guard player.currentItem != nil, seconds > 0 else { return }
        finishOutgoing()
        fadeIn?.cancel()
        fadeIn = nil
        // Detach the playing item so the next load cannot stop it, then give it its own fade.
        let fading = player
        if let timeObserver { fading.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedEndObserver { NotificationCenter.default.removeObserver(failedEndObserver) }
        endObserver = nil
        failedEndObserver = nil
        normalizationTask?.cancel()
        normalizationTask = nil
        itemGeneration += 1
        seekGeneration += 1
        outgoing = (fading, loader)
        loader = nil
        currentStream = nil
        measurement = nil
        normalizationTrack = nil
        player = AVPlayer()
        observePlayer()
        pendingFadeIn = seconds
        let start = fading.volume
        outgoingFade = Task { [weak self] in
            await Self.ramp(over: seconds) { fading.volume = start * CrossfadeCurve.fadeOut($0) }
            guard !Task.isCancelled else { return }
            self?.finishOutgoing()
        }
    }

    func cancelCrossfade() {
        finishOutgoing()
        pendingFadeIn = 0
        fadeIn?.cancel()
        fadeIn = nil
        player.volume = 1
    }

    private func finishOutgoing() {
        outgoingFade?.cancel()
        outgoingFade = nil
        guard let outgoing else { return }
        outgoing.player.pause()
        outgoing.player.replaceCurrentItem(with: nil)
        outgoing.loader?.cancelAll()
        self.outgoing = nil
    }

    /// Calls `update` with progress from 0 to 1 about every 50 ms for `seconds`.
    private static func ramp(over seconds: TimeInterval, update: @MainActor (Double) -> Void) async {
        let start = Date()
        while !Task.isCancelled {
            let progress = Date().timeIntervalSince(start) / seconds
            update(min(progress, 1))
            if progress >= 1 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func seek(to position: TimeInterval) {
        guard player.currentItem != nil else { return }
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        player.seek(to: time(position), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seeking = false
                self.publishPosition()
            }
        }
    }

    func setNormalization(_ normalization: PlaybackNormalization) {
        guard self.normalization != normalization else { return }
        self.normalization = normalization
        if normalization == .off {
            normalizationTask?.cancel()
            normalizationTask = nil
        }
        normalizeIfNeeded()
    }

    func setEqualizer(_ equalizer: PlaybackEqualizer) {
        let toggled = equalizer.enabled != self.equalizer.enabled
        self.equalizer = equalizer
        equalizerSettings.update(equalizer)
        if toggled { normalizeIfNeeded() }
    }

    /// Installs one audio tap for the equalizer and loudness normalization, or removes it when both are off.
    private func normalizeIfNeeded() {
        guard let item = player.currentItem, let stream = currentStream else { return }
        let normalize = normalization != .off
        guard normalize || equalizer.enabled else {
            item.audioMix = nil
            return
        }
        if let normalizationTrack {
            let gain: Float = normalize ? measurement?.gain(for: normalization) ?? 1 : 1
            item.audioMix = PlaybackAudioTap.audioMix(for: normalizationTrack, gain: gain,
                                                      equalizer: equalizer.enabled ? equalizerSettings : nil)
            if !normalize || measurement != nil { return }
        }
        guard normalizationTask == nil else { return }
        normalizationTask = Task(priority: .utility) { [weak self] in
            var track = self?.normalizationTrack
            if track == nil { track = try? await item.asset.loadTracks(withMediaType: .audio).first }
            guard let self, !Task.isCancelled, self.player.currentItem == item else { return }
            guard let track else {
                self.normalizationTask = nil
                return
            }
            let firstLoad = self.normalizationTrack == nil
            self.normalizationTrack = track
            guard self.normalization != .off, self.measurement == nil else {
                self.normalizationTask = nil
                if firstLoad { self.normalizeIfNeeded() }
                return
            }
            // Equalizer first, at unit gain, while loudness is measured.
            if firstLoad, self.equalizer.enabled {
                item.audioMix = PlaybackAudioTap.audioMix(for: track, gain: 1, equalizer: self.equalizerSettings)
            }
            let measurementTask = Task.detached(priority: .utility) {
                try? await PlaybackLevelMeasurement.measure(stream)
            }
            let measurement = await withTaskCancellationHandler {
                await measurementTask.value
            } onCancel: {
                measurementTask.cancel()
            }
            guard !Task.isCancelled, self.player.currentItem == item else { return }
            self.normalizationTask = nil
            guard let measurement else { return }
            self.measurement = measurement
            self.normalizeIfNeeded()
        }
    }

    func reset() {
        normalizationTask?.cancel()
        normalizationTask = nil
        measurement = nil
        normalizationTrack = nil
        currentStream = nil
        itemGeneration += 1
        seekGeneration += 1
        seeking = false
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedEndObserver { NotificationCenter.default.removeObserver(failedEndObserver) }
        endObserver = nil
        failedEndObserver = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        loader = nil
    }

    func resetMediaServices() {
        cancelCrossfade()
        reset()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation = nil
        player = AVPlayer()
        observePlayer()
    }

    private func observe(_ item: AVPlayerItem, generation: Int) {
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.itemGeneration == generation, let item = self.player.currentItem else { return }
                if item.status == .failed { self.onEvent?(.failed(.media)) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemGeneration == generation else { return }
                self.onEvent?(.ended)
            }
        }
        failedEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemGeneration == generation else { return }
                self.onEvent?(.failed(.media))
            }
        }
    }

    private func publishStatus() {
        guard player.currentItem != nil else { return }
        switch player.timeControlStatus {
        case .playing: onEvent?(.playing)
        case .waitingToPlayAtSpecifiedRate: onEvent?(.buffering)
        case .paused: break
        @unknown default: break
        }
    }

    private func publishPosition() {
        guard let item = player.currentItem, !seeking else { return }
        let duration = item.duration.seconds
        let position = player.currentTime().seconds
        if position.isFinite { onEvent?(.position(position, duration: duration.isFinite && duration > 0 ? duration : nil)) }
    }

    private func ensureCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard itemGeneration == generation else { throw CancellationError() }
    }

    private func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds.isFinite ? max(0, seconds) : 0, preferredTimescale: 600)
    }

    private func boundedPosition(_ position: TimeInterval, asset: AVURLAsset) async -> TimeInterval {
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite else { return position }
        return min(position, max(0, seconds))
    }
}

@MainActor
private final class AudioRangeLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let chunkSize: Int64 = 512 * 1024

    private let stream: PlaybackStream
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    var onFailure: ((PlaybackFailure) -> Void)?

    init(stream: PlaybackStream) { self.stream = stream }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        MainActor.assumeIsolated { start(request) }
        return true
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest
    ) {
        MainActor.assumeIsolated { requests.removeValue(forKey: ObjectIdentifier(request))?.cancel() }
    }

    func cancelAll() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }

    private func start(_ request: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(request)
        requests[key] = Task { [weak self] in
            guard let self else { return }
            defer { requests.removeValue(forKey: key) }
            do {
                try await respond(to: request)
                try Task.checkCancellation()
                request.finishLoading()
            } catch is CancellationError {
                if !request.isCancelled { request.finishLoading(with: CancellationError()) }
            } catch {
                guard !request.isCancelled else { return }
                let failure = PlaybackFailure.from(error)
                request.finishLoading(with: failure)
                onFailure?(failure)
            }
        }
    }

    private func respond(to request: AVAssetResourceLoadingRequest) async throws {
        if let content = request.contentInformationRequest {
            content.contentType = stream.contentType
            content.contentLength = stream.length
            content.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { return }

        let offset = max(data.currentOffset, data.requestedOffset)
        guard offset >= 0, offset <= stream.length, data.requestedOffset >= 0 else { throw PlaybackFailure.invalidStream }
        let remaining = max(0, stream.length - data.requestedOffset)
        let end = data.requestsAllDataToEndOfResource
            ? stream.length : data.requestedOffset + min(remaining, Int64(data.requestedLength))
        var position = offset
        while position < end {
            try Task.checkCancellation()
            let length = min(Self.chunkSize, end - position)
            let bytes = try await stream.read(position...(position + length - 1))
            try Task.checkCancellation()
            guard Int64(bytes.count) == length else { throw PlaybackFailure.invalidStream }
            data.respond(with: bytes)
            position += length
        }
    }
}

extension PlaybackFailure {
    static func from(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        switch error {
        case APIError.httpStatus(401, _): return .unauthorized
        case ConnectionError.differentServer: return .differentServer
        case APIError.insecureTransportConsentRequired, APIError.insecureConnectionBlocked: return .insecureAddress
        case APIError.transportFailure: return .network
        case APIError.httpStatus, APIError.invalidAddress, APIError.invalidResponse, APIError.decodingFailure:
            return .invalidStream
        default: return .media
        }
    }
}
