import AVFoundation
import Foundation
import MediaPlayer
import Network

enum PlaybackAudioEvent {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case outputDisconnected
    case mediaServicesReset
}

@MainActor
protocol PlaybackAudioSession: AnyObject {
    var onEvent: ((PlaybackAudioEvent) -> Void)? { get set }
    func activate() throws
    func deactivate()
}

@MainActor
final class SystemPlaybackAudioSession: PlaybackAudioSession {
    var onEvent: ((PlaybackAudioEvent) -> Void)?
    private let session: AVAudioSession
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var active = false

    init(session: AVAudioSession = .sharedInstance(), notifications: NotificationCenter = .default) {
        self.session = session
        self.notifications = notifications
        observe(AVAudioSession.interruptionNotification) { [weak self] info in
            guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self?.active = false
                self?.onEvent?(.interruptionBegan)
            } else {
                let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let resume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                self?.onEvent?(.interruptionEnded(shouldResume: resume))
            }
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] info in
            let rawReason = info?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self?.onEvent?(.outputDisconnected)
            }
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.active = false
            self?.onEvent?(.mediaServicesReset)
        }
    }

    deinit { observers.forEach(notifications.removeObserver) }

    func activate() throws {
        guard !active else { return }
        // The playback category supplies Bluetooth A2DP and AirPlay routes through the system.
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        active = true
    }

    func deactivate() {
        guard active else { return }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            active = false
        } catch {
            // A subsequent pause can retry deactivating this session.
        }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor ([AnyHashable: Any]?) -> Void) {
        observers.append(notifications.addObserver(forName: name, object: session, queue: .main) { notification in
            MainActor.assumeIsolated { action(notification.userInfo) }
        })
    }
}

enum PlaybackRemoteCommand {
    case play, pause, toggle, next, previous
    case seek(TimeInterval)
}

struct PlaybackMetadata {
    let track: LibraryTrack?
    var podcast: PodcastSelection? = nil
    let position: TimeInterval
    let duration: TimeInterval?
    let isPlaying: Bool
    let wantsPlayback: Bool
    let queueIndex: Int
    let queueCount: Int
    let canSkipNext: Bool
    let canSkipPrevious: Bool
}

@MainActor
protocol PlaybackRemoteControlling: AnyObject {
    var onCommand: ((PlaybackRemoteCommand) -> Void)? { get set }
    func publish(_ metadata: PlaybackMetadata?)
}

@MainActor
final class SystemPlaybackRemoteControls: PlaybackRemoteControlling {
    var onCommand: ((PlaybackRemoteCommand) -> Void)?
    private let commands: MPRemoteCommandCenter
    private let nowPlaying: MPNowPlayingInfoCenter
    private var targets: [(MPRemoteCommand, Any)] = []

    init(commands: MPRemoteCommandCenter = .shared(), nowPlaying: MPNowPlayingInfoCenter = .default()) {
        self.commands = commands
        self.nowPlaying = nowPlaying
        register(commands.playCommand) { _ in .play }
        register(commands.pauseCommand) { _ in .pause }
        register(commands.togglePlayPauseCommand) { _ in .toggle }
        register(commands.nextTrackCommand) { _ in .next }
        register(commands.previousTrackCommand) { _ in .previous }
        register(commands.changePlaybackPositionCommand) {
            ($0 as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
        publish(nil)
    }

    deinit { targets.forEach { $0.0.removeTarget($0.1) } }

    func publish(_ metadata: PlaybackMetadata?) {
        commands.playCommand.isEnabled = metadata.map { !$0.wantsPlayback } ?? false
        commands.pauseCommand.isEnabled = metadata?.wantsPlayback ?? false
        commands.togglePlayPauseCommand.isEnabled = metadata != nil
        commands.nextTrackCommand.isEnabled = metadata?.canSkipNext ?? false
        commands.previousTrackCommand.isEnabled = metadata?.canSkipPrevious ?? false
        commands.changePlaybackPositionCommand.isEnabled = metadata?.duration != nil
        guard let metadata else {
            nowPlaying.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.podcast?.episode.title ?? metadata.track?.title ?? "",
            MPMediaItemPropertyArtist: metadata.podcast?.show.author ?? metadata.track?.artist ?? "",
            MPMediaItemPropertyAlbumTitle: metadata.podcast?.show.name ?? metadata.track?.album ?? "",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: metadata.position,
            MPNowPlayingInfoPropertyPlaybackRate: metadata.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: metadata.queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: metadata.queueCount
        ]
        info[MPMediaItemPropertyPlaybackDuration] = metadata.duration
        nowPlaying.nowPlayingInfo = info
    }

    private func register(_ command: MPRemoteCommand, map: @escaping (MPRemoteCommandEvent) -> PlaybackRemoteCommand?) {
        let target = command.addTarget { [weak self] event in
            guard let action = map(event) else { return .commandFailed }
            Task { @MainActor in self?.onCommand?(action) }
            return .success
        }
        targets.append((command, target))
    }
}

@MainActor
protocol PlaybackNetworkMonitoring: AnyObject {
    func start(_ update: @escaping @MainActor (PlaybackNetwork) -> Void)
}

@MainActor
final class SystemPlaybackNetworkMonitor: PlaybackNetworkMonitoring {
    private let monitor = NWPathMonitor()

    deinit { monitor.cancel() }

    func start(_ update: @escaping @MainActor (PlaybackNetwork) -> Void) {
        monitor.pathUpdateHandler = { path in
            let network: PlaybackNetwork
            if path.status != .satisfied {
                network = .unavailable
            } else {
                network = path.usesInterfaceType(.cellular) ? .cellular : .wifiOrWired
            }
            Task { @MainActor in update(network) }
        }
        monitor.start(queue: DispatchQueue(label: "app.downtify.playback-network"))
    }
}
