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
    func reset()
    func resetMediaServices()
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
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedEndObserver { NotificationCenter.default.removeObserver(failedEndObserver) }
    }

    func load(_ stream: PlaybackStream, at position: TimeInterval) async throws {
        reset()
        let generation = itemGeneration
        var location = URLComponents()
        location.scheme = "downtify-stream"
        location.host = "audio"
        location.path = "/track.\(stream.fileExtension)"
        guard let url = location.url else { throw PlaybackFailure.invalidStream }

        let asset = AVURLAsset(url: url)
        let loader = AudioRangeLoader(stream: stream)
        self.loader = loader
        loader.onFailure = { [weak self] failure in
            guard self?.itemGeneration == generation else { return }
            self?.onEvent?(.failed(failure))
        }
        asset.resourceLoader.setDelegate(loader, queue: .main)

        guard try await asset.load(.isPlayable) else { throw PlaybackFailure.unsupportedFormat }
        try ensureCurrent(generation)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observe(item, generation: generation)
        if position > 0 {
            let target = await boundedPosition(position, asset: asset)
            try ensureCurrent(generation)
            let completed = await player.seek(to: time(target), toleranceBefore: .zero, toleranceAfter: .zero)
            try ensureCurrent(generation)
            guard completed else { throw PlaybackFailure.media }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

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

    func reset() {
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
        case APIError.insecureTransportConsentRequired: return .insecureAddress
        case APIError.transportFailure: return .network
        case APIError.httpStatus, APIError.invalidAddress, APIError.invalidResponse, APIError.decodingFailure:
            return .invalidStream
        default: return .media
        }
    }
}
