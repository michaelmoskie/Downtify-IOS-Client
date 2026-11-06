import SwiftUI

struct AppShellView: View {
    let name: String
    @ObservedObject var presentation: SessionPresentationCoordinator
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @AppStorage(DowntifyAppearance.storageKey) private var appearance = DowntifyAppearance.system

    var body: some View {
        Group {
            switch presentation.destination {
            case .loading:
                ProgressView("Checking saved connection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DowntifyPalette(oled: appearance == .oled).background.ignoresSafeArea())
            case let .connection(error):
                FoundationView(name: name, recoverableError: error, retryAction: presentation.retry,
                               connection: presentation.connectionService, discovery: presentation.serverDiscovery,
                               deviceName: name)
            case let .library(server):
                LibraryHomeView(server: server, library: library, playback: playback, appearance: $appearance,
                                connection: presentation.connectionService,
                                signOut: { try await presentation.connectionService.signOut() })
            }
        }
        .downtifyAppearance(appearance)
        .task { presentation.start(); library.start() }
    }
}

extension LibraryTrack {
    var displayTitle: String { title.isEmpty ? String(localized: "Unknown title") : title }
    var displayArtist: String { artist.isEmpty ? String(localized: "Unknown artist") : artist }
    var accessibleMetadata: String {
        album.isEmpty ? String(localized: "\(displayTitle), \(displayArtist)")
            : String(localized: "\(displayTitle), \(displayArtist), \(album)")
    }
}

struct TrackRow: View {
    let track: LibraryTrack

    var body: some View {
        DowntifyMediaRow(title: track.displayTitle, subtitle: track.displayArtist,
                         detail: track.album.isEmpty ? nil : track.album) {
            TrackArtwork(track: track, size: 56)
        } accessory: {
            Text(durationText(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(DowntifyStyle.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Lives at the navigation boundary so playback updates do not invalidate library rows.
struct PlaybackDock: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.downtifyPalette) private var palette
    @State private var showingNowPlaying = false

    var body: some View {
        Group {
            if playback.podcast != nil || playback.queue.current != nil {
                MiniPlayerView(playback: playback) { showingNowPlaying = true }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, DowntifyStyle.Space.regular)
                    .padding(.vertical, DowntifyStyle.Space.small)
                    .frame(maxWidth: .infinity)
                    .background(palette.background)
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(playback: playback)
                .presentationDragIndicator(.visible)
        }
    }
}

private struct MiniPlayerView: View {
    @ObservedObject var playback: PlaybackController
    let open: () -> Void
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var track: LibraryTrack? { playback.queue.current?.track }
    private var isActive: Bool { playback.phase == .playing || playback.phase == .buffering || playback.phase == .loading }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            if let podcast = playback.podcast {
                Button(action: open) {
                    DowntifyMediaRow(title: podcast.episode.title, subtitle: podcast.show.name, accessibilityLineLimit: 2) {
                        PodcastArtwork(show: podcast.show, size: 44)
                    } accessory: { EmptyView() }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing, \(podcast.episode.title), \(podcast.show.name)")
                .accessibilityHint("Open Now Playing")
            } else if let track {
                Button(action: open) {
                    DowntifyMediaRow(title: track.displayTitle, subtitle: track.displayArtist, accessibilityLineLimit: 2) {
                        TrackArtwork(track: track, size: 44)
                    } accessory: {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing, \(track.displayTitle) by \(track.displayArtist)")
                .accessibilityHint("Open Now Playing")
            }
            HStack(spacing: 4) {
                if case .failed = playback.phase {
                    Button { playback.play() } label: {
                        Image(systemName: "arrow.clockwise").downtifyControlTarget()
                    }
                    .accessibilityLabel("Retry playback")
                } else {
                    Button { playback.togglePlayback() } label: {
                        Image(systemName: isActive ? "pause.fill" : "play.fill")
                            .downtifyControlTarget()
                    }
                    .accessibilityLabel(isActive ? "Pause" : "Play")
                }
                if playback.podcast == nil {
                    Button { playback.skipNext() } label: {
                        Image(systemName: "forward.end.fill").downtifyControlTarget()
                    }
                    .accessibilityLabel("Next track")
                    .disabled(playback.queue.next(automatic: false) == nil)
                }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            if let duration = playback.duration, duration.isFinite, duration > 0 {
                ProgressView(value: min(playback.position, duration), total: duration)
                    .padding(.horizontal, 12)
                    .accessibilityHidden(true)
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
        }
    }
}

private struct NowPlayingView: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var showingQueue = false

    private var track: LibraryTrack? { playback.queue.current?.track }
    private var activelyPlaying: Bool { playback.phase == .playing || playback.phase == .buffering || playback.phase == .loading }

    private var usesWideLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let layout = usesWideLayout
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: DowntifyStyle.Space.large))
                    : AnyLayout(VStackLayout(spacing: DowntifyStyle.Space.large))
                layout {
                    Group {
                        if let podcast = playback.podcast {
                            PodcastArtwork(show: podcast.show, size: artworkSize)
                        } else {
                            TrackArtwork(track: track, size: artworkSize)
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(spacing: DowntifyStyle.Space.regular) {
                        trackMetadata
                        phaseDescription
                            .font(.subheadline)
                            .foregroundStyle(DowntifyStyle.secondaryText)
                            .multilineTextAlignment(.center)
                        timeline
                        transportControls
                        if playback.podcast == nil {
                            queueControls
                        } else {
                            if playback.podcastProgressSaveFailed {
                                Text("Could not save playback progress to the server.")
                                    .font(.footnote)
                                    .foregroundStyle(DowntifyStyle.error)
                            }
                            if track != nil {
                                Button("Back to music", systemImage: "music.note") { playback.returnToMusic() }
                            }
                        }
                    }
                    .frame(maxWidth: 400)
                }
                .padding(DowntifyStyle.Space.regular)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingQueue) {
            PlaybackQueueSheet(playback: playback)
                .presentationDragIndicator(.visible)
        }
    }

    private var trackMetadata: some View {
        VStack(spacing: 5) {
            Text(playback.podcast?.episode.title ?? track?.displayTitle ?? String(localized: "Unknown title"))
                .font(.title2.weight(.bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityAddTraits(.isHeader)
            Text(playback.podcast?.show.name ?? track?.displayArtist ?? String(localized: "Unknown artist"))
                .font(.title3)
                .foregroundStyle(DowntifyStyle.secondaryText)
            if let album = playback.podcast == nil ? track?.album : playback.podcast?.show.author, !album.isEmpty {
                Text(album)
                    .font(.subheadline)
                    .foregroundStyle(DowntifyStyle.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var transportControls: some View {
        HStack(spacing: DowntifyStyle.Space.regular) {
            if playback.podcast != nil {
                Button { playback.seek(to: playback.position - 15) } label: {
                    Image(systemName: "gobackward.15").font(.title2).downtifyControlTarget()
                }
                .accessibilityLabel("Back 15 seconds")
            } else {
                Button { playback.skipPrevious() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                        .downtifyControlTarget()
                }
                .accessibilityLabel("Previous track")
                .disabled(track == nil)
            }
            if case .failed = playback.phase {
                Button { playback.play() } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 56))
                        .downtifyControlTarget()
                }
                .accessibilityLabel("Retry playback")
            } else {
                Button { playback.togglePlayback() } label: {
                    Image(systemName: activelyPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56)).downtifyControlTarget()
                }
                .accessibilityLabel(activelyPlaying ? "Pause" : "Play")
                .disabled(track == nil && playback.podcast == nil)
            }
            if playback.podcast != nil {
                Button { playback.seek(to: playback.position + 30) } label: {
                    Image(systemName: "goforward.30").font(.title2).downtifyControlTarget()
                }
                .accessibilityLabel("Forward 30 seconds")
            } else {
                Button { playback.skipNext() } label: {
                    Image(systemName: "forward.end.fill").font(.title2)
                        .downtifyControlTarget()
                }
                .accessibilityLabel("Next track")
                .disabled(playback.queue.next(automatic: false) == nil)
            }
        }
        .buttonStyle(.borderless)
    }

    private var queueControls: some View {
        HStack(spacing: DowntifyStyle.Space.regular) {
            Button { playback.setShuffle(playback.queue.shuffledIDs == nil) } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.queue.shuffledIDs == nil ? DowntifyStyle.secondaryText : DowntifyStyle.accent)
                    .downtifyControlTarget()
                    .background {
                        if playback.queue.shuffledIDs != nil {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(DowntifyStyle.accent)
                        }
                    }
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.queue.shuffledIDs == nil ? "Off" : "On")
            .accessibilityAddTraits(playback.queue.shuffledIDs == nil ? [] : .isSelected)

            Button { showingQueue = true } label: {
                Image(systemName: "list.bullet").downtifyControlTarget()
            }
            .accessibilityLabel("Play queue")

            Button { playback.setRepeat(nextRepeatMode) } label: {
                Image(systemName: repeatSymbol)
                    .foregroundStyle(playback.queue.repeatMode == .off ? DowntifyStyle.secondaryText : DowntifyStyle.accent)
                    .downtifyControlTarget()
                    .background {
                        if playback.queue.repeatMode != .off {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(DowntifyStyle.accent)
                        }
                    }
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatDescription)
            .accessibilityHint("Changes repeat mode")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private var nextRepeatMode: PlaybackRepeat {
        switch playback.queue.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    private var repeatSymbol: String {
        playback.queue.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatDescription: String {
        switch playback.queue.repeatMode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    private var artworkSize: CGFloat {
        if usesWideLayout { return 200 }
        return dynamicTypeSize.isAccessibilitySize ? 172 : 240
    }

    @ViewBuilder
    private var phaseDescription: some View {
        switch playback.phase {
        case .idle: Text("Ready")
        case .loading: Label(playback.podcast == nil ? "Loading track" : "Loading episode", systemImage: "hourglass")
        case .paused: Text("Paused")
        case .playing: Label("Playing", systemImage: "waveform")
        case .buffering: Label("Buffering", systemImage: "waveform")
        case .ended: Text("Finished")
        case .failed(let failure):
            Label(playbackFailureMessage(failure, isPodcast: playback.podcast != nil), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DowntifyStyle.error)
        }
    }

    private var timeline: some View {
        VStack(spacing: 5) {
            if let duration = playback.duration, duration.isFinite, duration > 0 {
                Slider(value: Binding(get: { min(playback.position, duration) }, set: { playback.seek(to: $0, checkpoint: false) }),
                       in: 0...duration, onEditingChanged: { if !$0 { playback.finishScrubbing() } })
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(spokenDuration(playback.position)) of \(spokenDuration(duration))")
                HStack {
                    Text(durationText(playback.position))
                    Spacer()
                    Text("−\(durationText(max(0, duration - playback.position)))")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(DowntifyStyle.secondaryText)
            } else {
                Text("Duration unavailable")
                    .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Slider(value: .constant(0), in: 0...1).disabled(true)
                    .accessibilityLabel("Playback position unavailable")
            }
        }
    }
}

private struct PlaybackQueueSheet: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.downtifyPalette) private var palette

    private var visibleEntries: [PlaybackQueueEntry] {
        guard let currentIndex = playback.queue.currentIndex else { return [] }
        return Array(playback.queue.order.dropFirst(currentIndex))
    }

    private var upcomingEntries: [PlaybackQueueEntry] { Array(visibleEntries.dropFirst()) }

    var body: some View {
        NavigationStack {
            List {
                if visibleEntries.isEmpty {
                    DowntifyUnavailableView(title: "Queue is empty", symbol: "music.note.list")
                        .listRowBackground(palette.surface)
                } else {
                    if let current = visibleEntries.first {
                        QueueEntryRow(entry: current, isCurrent: true, playback: playback)
                            .listRowBackground(palette.surface)
                    }
                    ForEach(upcomingEntries) { entry in
                        QueueEntryRow(entry: entry, isCurrent: false, playback: playback)
                            .listRowBackground(palette.surface)
                    }
                    .onMove(perform: moveEntries)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .toolbarBackground(palette.background, for: .navigationBar)
            .navigationTitle("Play Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton().disabled(visibleEntries.count < 2) }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        let countBeforeDestination = source.filter { $0 < destination }.count
        let finalDestination = max(0, min(upcomingEntries.count - source.count, destination - countBeforeDestination))
        var reordered = upcomingEntries.map(\.id)
        let moved = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) { reordered.remove(at: index) }
        reordered.insert(contentsOf: moved, at: finalDestination)
        guard let startIndex = playback.queue.currentIndex else { return }
        // Resolve each target by UUID so duplicate tracks remain distinct.
        for (offset, id) in reordered.enumerated() {
            playback.move(id, to: startIndex + 1 + offset)
        }
    }
}

private struct QueueEntryRow: View {
    let entry: PlaybackQueueEntry
    let isCurrent: Bool
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: DowntifyStyle.Space.small) {
            Button { playback.select(entry.id) } label: {
                DowntifyMediaRow(title: entry.track.displayTitle, subtitle: entry.track.displayArtist) {
                    TrackArtwork(track: entry.track, size: 44)
                } accessory: {
                    if isCurrent {
                        Label("Current track", systemImage: "speaker.wave.2.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(DowntifyStyle.accent)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(entry.track.accessibleMetadata))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint(isCurrent ? "Current queue entry" : "Play this queue entry")

            Button(role: .destructive) { playback.remove(entry.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DowntifyStyle.secondaryText)
                    .downtifyControlTarget()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(entry.track.displayTitle) from queue")
        }
        .padding(.vertical, 3)
    }
}

@MainActor
final class ArtworkLoader: ObservableObject {
    private let connection: ConnectionService
    private let transport: any HTTPDataLoading
    private let cache = NSCache<NSString, UIImage>()
    private var cachedSession: DeviceSession?

    init(connection: ConnectionService, transport: any HTTPDataLoading = ConnectionHTTPTransport()) {
        self.connection = connection
        self.transport = transport
        cache.countLimit = 200
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for track: LibraryTrack, size: Int) async -> UIImage? {
        guard track.hasCover, !track.id.isEmpty else { return nil }
        return await image(key: "track:\(track.id):\(size)") { address in
            let url = address.url(for: "/api/v1/tracks").appendingPathComponent(track.id).appendingPathComponent("cover")
            return (url, URLQueryItem(name: "size", value: String(size)))
        }
    }

    func playlistImage(file: String) async -> UIImage? {
        guard !file.isEmpty else { return nil }
        return await image(key: "playlist:\(file)") { address in
            (address.url(for: "/playlist-cover"), URLQueryItem(name: "file", value: file))
        }
    }

    private func image(key: String, route: (ServerAddress) -> (URL, URLQueryItem)) async -> UIImage? {
        do {
            guard let session = try await connection.restoreSession() else {
                cache.removeAllObjects()
                cachedSession = nil
                return nil
            }
            if cachedSession != session {
                cache.removeAllObjects()
                cachedSession = session
            }
            if let image = cache.object(forKey: key as NSString) { return image }
            let address = try await LibraryAPIClient(transport: transport).verifiedAddress(for: session)
            let (url, query) = route(address)
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.queryItems = [query]
            guard let requestURL = components.url else { return nil }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
            let data = try await APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
                .send(request, to: address)
            guard !Task.isCancelled, try await connection.restoreSession() == session,
                  cachedSession == session, let image = UIImage(data: data) else { return nil }
            cache.setObject(image, forKey: key as NSString, cost: data.count)
            return image
        } catch {
            return nil
        }
    }
}

struct TrackArtwork: View {
    let track: LibraryTrack?
    let size: CGFloat
    var playlistCover: String? = nil
    @EnvironmentObject private var artwork: ArtworkLoader
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ArtworkRequest: Equatable {
        let track: LibraryTrack?
        let cover: String?
        let size: Int
    }

    private var requestSize: Int { size > 150 ? 600 : 150 }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
                    .transition(.opacity)
            } else {
                ArtworkPlaceholder(size: size)
                    .transition(.opacity)
            }
        }
        .task(id: ArtworkRequest(track: track, cover: playlistCover, size: requestSize)) {
            image = nil
            var loadedImage: UIImage?
            if let playlistCover, !playlistCover.isEmpty {
                loadedImage = await artwork.playlistImage(file: playlistCover)
            }
            if loadedImage == nil, let track, track.hasCover, !Task.isCancelled {
                loadedImage = await artwork.image(for: track, size: requestSize)
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) {
                image = loadedImage
            }
        }
    }
}

private struct ArtworkPlaceholder: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(LinearGradient(colors: [DowntifyStyle.accent.opacity(0.25), DowntifyStyle.accent.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.30, weight: .light))
                .foregroundStyle(DowntifyStyle.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

func playbackFailureMessage(_ failure: PlaybackFailure, isPodcast: Bool = false) -> String {
    switch failure {
    case .signedOut: "Sign in to play this track"
    case .differentServer: isPodcast ? "This episode belongs to a different server" : "This track belongs to a different server"
    case .insecureAddress: "The server connection is not secure"
    case .unauthorized: "Your session needs to be refreshed"
    case .network: "Could not reach the server"
    case .invalidStream: "The audio stream is unavailable"
    case .unsupportedFormat: "This audio format is unsupported"
    case .media: isPodcast ? "Could not play this episode" : "Could not play this track"
    case .audioSession: "Audio playback could not start"
    }
}

private func durationText(_ duration: Double) -> String {
    guard duration >= 0, let seconds = Int(exactly: duration.rounded()) else { return "—:—" }
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

func spokenDuration(_ duration: Double) -> String {
    guard duration >= 0, let seconds = Int(exactly: duration.rounded()) else {
        return String(localized: "Duration unavailable")
    }
    return Duration.seconds(seconds)
        .formatted(.units(allowed: [.minutes, .seconds], width: .wide, zeroValueUnits: .show(length: 1)))
}

#if DEBUG
private struct LibraryDesignPreviews: PreviewProvider {
    private static let sample = LibraryTrack(
        id: "preview-track", file: "", title: "On the Other Side of the City at Dawn",
        artist: "The Long Distance Orchestra", artists: [], album: "Quiet Streets",
        albumArtist: "", albumID: "", artistID: "", trackNumber: 1, year: "", duration: 223,
        codec: "", bitrate: 0, sampleRate: 0, channels: 0, size: 0, added: 0,
        hasCover: false, isExplicit: false, playlists: []
    )

    static var previews: some View {
        Group {
            NavigationStack {
                ScrollView {
                    DowntifyCard { TrackRow(track: sample) }
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
                .background(DowntifyPalette().background)
                .navigationTitle("Library")
            }
            .downtifyAppearance(.light)
            .environmentObject(ArtworkLoader(connection: ConnectionService()))
            .previewDisplayName("Library row · Light")

            NavigationStack {
                ScrollView {
                    VStack {
                        DowntifyCard { TrackRow(track: sample) }
                        DowntifyUnavailableView(title: "Library unavailable", symbol: "exclamationmark.triangle",
                                                message: Text("The server could not be reached."), retry: {})
                    }
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.black)
                .navigationTitle("Library")
            }
            .downtifyAppearance(.oled)
            .environmentObject(ArtworkLoader(connection: ConnectionService()))
            .dynamicTypeSize(.accessibility3)
            .environment(\.accessibilityReduceMotion, true)
            .previewDisplayName("Library error · OLED, Large Type")
        }
    }
}
#endif
