import SwiftUI

struct AppShellView: View {
    let name: String
    @ObservedObject var presentation: SessionPresentationCoordinator
    @ObservedObject var library: LibraryPresentationModel
    @ObservedObject var playback: PlaybackController

    var body: some View {
        Group {
            switch presentation.destination {
            case .loading:
                ProgressView("Checking saved connection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DowntifyStyle.background.ignoresSafeArea())
            case let .connection(error):
                FoundationView(name: name, recoverableError: error, retryAction: presentation.retry,
                               connection: presentation.connectionService, discovery: presentation.serverDiscovery,
                               deviceName: name)
            case let .library(server):
                LibraryHomeView(server: server, library: library, playback: playback,
                                signOut: { try presentation.connectionService.signOut() })
            }
        }
        .tint(DowntifyStyle.accent)
        .task { presentation.start(); library.start() }
    }
}

private struct LibraryHomeView: View {
    let server: SessionPresentationCoordinator.ServerSummary
    @ObservedObject var library: LibraryPresentationModel
    @ObservedObject var playback: PlaybackController
    let signOut: () throws -> Void
    @State private var searchText = ""
    @State private var showingSignOutConfirmation = false
    @State private var signOutError: String?
    @State private var showingNowPlaying = false

    private var sortedTracks: [LibraryTrack] {
        LibraryTrackOrdering.sorted(library.tracks)
    }

    private var visibleTracks: [LibraryTrack] {
        LibraryTrackOrdering.matching(sortedTracks, query: searchText)
    }

    var body: some View {
        NavigationStack {
            trackContent
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let username = server.username {
                            Label("Signed in as \(username)", systemImage: "person.crop.circle")
                        }
                        Button("Sign out", role: .destructive) { showingSignOutConfirmation = true }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account options")
                }
            }
            .confirmationDialog("Sign out of \(server.name)?", isPresented: $showingSignOutConfirmation, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    do { try signOut() } catch { signOutError = "Could not sign out. Please try again." }
                }
            } message: {
                Text("You can reconnect to this server at any time.")
            }
            .alert("Sign out failed", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
                Button("OK", role: .cancel) { signOutError = nil }
            } message: { Text(signOutError ?? "") }
            .searchable(text: $searchText, prompt: "Songs, artists, albums")
            .background(DowntifyStyle.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playback.queue.current != nil {
                    MiniPlayerView(playback: playback) { showingNowPlaying = true }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .background(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: $showingNowPlaying) {
                NowPlayingView(playback: playback)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var trackContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                if library.tracks.isEmpty {
                    libraryEmptyState
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.headline).accessibilityAddTraits(.isHeader)
                        if let username = server.username {
                            Text("Signed in as \(username)").font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                        }
                    }
                    Spacer()
                    Button { Task { await library.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Refresh library")
                    .disabled(library.state == .refreshing || library.state == .loading)
                }
                if !library.tracks.isEmpty, case .cachedError(let message) = library.state {
                    Label(message, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !library.tracks.isEmpty, case .storageFailure(let message) = library.state {
                    Label(message, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if library.state == .refreshing { ProgressView("Refreshing library…").font(.caption) }
                if visibleTracks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                playback.replaceQueue(visibleTracks, startingAt: index)
                            } label: {
                                TrackRow(track: track)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(track.title), \(track.artist), \(track.album), \(durationText(track.duration))")
                            .accessibilityHint("Play this song and replace the current queue")
                            if index < visibleTracks.count - 1 { Divider().padding(.leading, 68) }
                        }
                    }
                    .background(DowntifyStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding(.horizontal, DowntifyStyle.Space.regular)
            .padding(.top, DowntifyStyle.Space.small)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await library.refresh() }
    }

    @ViewBuilder
    private var libraryEmptyState: some View {
        switch library.state {
        case .loading:
            ProgressView("Loading your library…")
                .frame(maxWidth: .infinity, minHeight: 220)
        case .empty:
            VStack(spacing: 12) {
                ContentUnavailableView("Your library is empty", systemImage: "music.note.list",
                                       description: Text("Music saved on this server will appear here."))
                retryLibraryButton
            }
                .frame(minHeight: 220)
        case .cachedError(let message):
            VStack(spacing: 12) {
                ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                retryLibraryButton
            }
                .frame(minHeight: 220)
        case .storageFailure(let message):
            VStack(spacing: 12) {
                ContentUnavailableView("Library unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(message))
                retryLibraryButton
            }
                .frame(minHeight: 220)
        default:
            EmptyView()
        }
    }

    private var retryLibraryButton: some View {
        Button { Task { await library.refresh() } } label: {
            Label("Try again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(library.state == .loading || library.state == .refreshing)
    }
}

private struct TrackRow: View {
    let track: LibraryTrack
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            TrackArtwork(track: track, size: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title.isEmpty ? "Unknown title" : track.title)
                    .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                    .font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText).lineLimit(1)
                if !track.album.isEmpty {
                    Text(track.album).font(.caption).foregroundStyle(DowntifyStyle.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(durationText(track.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(DowntifyStyle.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 68)
    }
}

private struct MiniPlayerView: View {
    @ObservedObject var playback: PlaybackController
    let open: () -> Void

    private var track: LibraryTrack? { playback.queue.current?.track }
    private var isActive: Bool { playback.phase == .playing || playback.phase == .buffering || playback.phase == .loading }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    TrackArtwork(track: track, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track?.title.isEmpty == false ? track!.title : "Unknown title")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track?.artist.isEmpty == false ? track!.artist : "Unknown artist")
                            .font(.caption).foregroundStyle(DowntifyStyle.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing, \(track?.title ?? "Unknown title") by \(track?.artist ?? "Unknown artist")")
            .accessibilityHint("Open the Now Playing screen")

            if case .failed = playback.phase {
                Button { playback.play() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Retry playback")
            } else {
                Button { playback.togglePlayback() } label: {
                    Image(systemName: isActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isActive ? "Pause" : "Play")
                .disabled(track == nil)
            }
            Button { playback.skipNext() } label: { Image(systemName: "forward.end.fill") }
                .accessibilityLabel("Next track")
                .disabled(playback.queue.next(automatic: false) == nil)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(DowntifyStyle.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(alignment: .bottom) {
            if let duration = playback.duration, duration > 0 {
                ProgressView(value: min(playback.position, duration), total: duration)
                    .tint(DowntifyStyle.accent).frame(height: 2).padding(.horizontal, 10)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct NowPlayingView: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingQueue = false

    private var track: LibraryTrack? { playback.queue.current?.track }
    private var activelyPlaying: Bool { playback.phase == .playing || playback.phase == .buffering || playback.phase == .loading }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                TrackArtwork(track: track, size: artworkSize)
                    .padding(.top, 28)
                    .accessibilityLabel("Album artwork")
                VStack(spacing: 5) {
                    Text(track?.title.isEmpty == false ? track!.title : "Unknown title")
                        .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    Text(track?.artist.isEmpty == false ? track!.artist : "Unknown artist")
                        .font(.title3).foregroundStyle(DowntifyStyle.secondaryText).multilineTextAlignment(.center)
                    if let album = track?.album, !album.isEmpty {
                        Text(album).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
                phaseDescription
                    .font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                    .frame(minHeight: 22)
                    timeline
                HStack(spacing: 38) {
                    Button { playback.skipPrevious() } label: {
                        Image(systemName: "backward.end.fill").font(.title2)
                    }
                    .accessibilityLabel("Previous track")
                    .disabled(track == nil)
                    if case .failed = playback.phase {
                        Button { playback.play() } label: {
                            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 56))
                        }
                        .accessibilityLabel("Retry playback")
                    } else {
                        Button { playback.togglePlayback() } label: {
                            Image(systemName: activelyPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                        }
                        .accessibilityLabel(activelyPlaying ? "Pause" : "Play")
                        .disabled(track == nil)
                    }
                    Button { playback.skipNext() } label: {
                        Image(systemName: "forward.end.fill").font(.title2)
                    }
                    .accessibilityLabel("Next track")
                    .disabled(playback.queue.next(automatic: false) == nil)
                }
                .buttonStyle(.plain)
                HStack(spacing: 28) {
                    Button { playback.setShuffle(playback.queue.shuffledIDs == nil) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(playback.queue.shuffledIDs == nil ? DowntifyStyle.secondaryText : DowntifyStyle.accent)
                    }
                    .accessibilityLabel("Shuffle")
                    .accessibilityValue(playback.queue.shuffledIDs == nil ? "Off" : "On")
                    .accessibilityAddTraits(playback.queue.shuffledIDs == nil ? [] : .isSelected)

                    Button { showingQueue = true } label: {
                        Label("Queue", systemImage: "list.bullet")
                    }
                    .accessibilityLabel("Play queue")

                    Button { playback.setRepeat(nextRepeatMode) } label: {
                        Image(systemName: repeatSymbol)
                            .foregroundStyle(playback.queue.repeatMode == .off ? DowntifyStyle.secondaryText : DowntifyStyle.accent)
                    }
                    .accessibilityLabel("Repeat")
                    .accessibilityValue(repeatDescription)
                    .accessibilityHint("Double tap to change repeat mode")
                }
                .buttonStyle(.plain)
                .font(.title3)
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(DowntifyStyle.background.ignoresSafeArea())
        .tint(DowntifyStyle.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
        .sheet(isPresented: $showingQueue) {
            PlaybackQueueSheet(playback: playback)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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

    private var artworkSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 190 : 260 }

    @ViewBuilder
    private var phaseDescription: some View {
        switch playback.phase {
        case .idle: Text("Ready")
        case .loading: Label("Loading track", systemImage: "hourglass")
        case .paused: Text("Paused")
        case .playing: Label("Playing", systemImage: "waveform")
        case .buffering: Label("Buffering", systemImage: "waveform")
        case .ended: Text("Finished")
        case .failed(let failure):
            Label(playbackFailureMessage(failure), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var timeline: some View {
        VStack(spacing: 5) {
            if let duration = playback.duration, duration.isFinite, duration > 0 {
                Slider(value: Binding(get: { min(playback.position, duration) }, set: { playback.seek(to: $0) }),
                       in: 0...duration)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(durationText(playback.position)) of \(durationText(duration))")
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

    private var visibleEntries: [PlaybackQueueEntry] {
        guard let currentIndex = playback.queue.currentIndex else { return [] }
        return Array(playback.queue.order.dropFirst(currentIndex))
    }

    private var upcomingEntries: [PlaybackQueueEntry] { Array(visibleEntries.dropFirst()) }

    var body: some View {
        NavigationStack {
            List {
                if visibleEntries.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "music.note.list")
                } else {
                    if let current = visibleEntries.first {
                        QueueEntryRow(entry: current, isCurrent: true, playback: playback)
                    }
                    ForEach(upcomingEntries) { entry in
                        QueueEntryRow(entry: entry, isCurrent: false, playback: playback)
                    }
                    .onMove(perform: moveEntries)
                }
            }
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
        HStack(spacing: 12) {
            Button { playback.select(entry.id) } label: {
                HStack(spacing: 12) {
                    TrackArtwork(track: entry.track, size: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.track.title.isEmpty ? "Unknown title" : entry.track.title).lineLimit(1)
                        Text(entry.track.artist.isEmpty ? "Unknown artist" : entry.track.artist)
                            .font(.caption).foregroundStyle(DowntifyStyle.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isCurrent { Text("Playing").font(.caption).foregroundStyle(DowntifyStyle.accent) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.track.title), \(entry.track.artist)\(isCurrent ? ", currently playing" : "")")
            .accessibilityHint(isCurrent ? "Currently playing" : "Play this queue entry")

            Button(role: .destructive) { playback.remove(entry.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(DowntifyStyle.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.track.title) from queue")
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
            let key = "\(track.id):\(size)" as NSString
            if let image = cache.object(forKey: key) { return image }
            let address = try await LibraryAPIClient(transport: transport).verifiedAddress(for: session)
            let url = address.url(for: "/api/v1/tracks")
                .appendingPathComponent(track.id).appendingPathComponent("cover")
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.queryItems = [URLQueryItem(name: "size", value: String(size))]
            guard let requestURL = components.url else { return nil }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
            let data = try await APIClient(session: transport, allowsInsecureRequests: session.allowsInsecureHTTP)
                .send(request, to: address)
            guard !Task.isCancelled, try await connection.restoreSession() == session,
                  cachedSession == session, let image = UIImage(data: data) else { return nil }
            cache.setObject(image, forKey: key, cost: data.count)
            return image
        } catch {
            return nil
        }
    }
}

private struct TrackArtwork: View {
    let track: LibraryTrack?
    let size: CGFloat
    @EnvironmentObject private var artwork: ArtworkLoader
    @State private var image: UIImage?

    private var requestSize: Int { size > 150 ? 600 : 150 }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
            } else {
                ArtworkPlaceholder(size: size)
            }
        }
        .task(id: track) {
            image = nil
            guard let track else { return }
            image = await artwork.image(for: track, size: requestSize)
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

private func playbackFailureMessage(_ failure: PlaybackFailure) -> String {
    switch failure {
    case .signedOut: "Sign in to play this track"
    case .differentServer: "This track belongs to a different server"
    case .insecureAddress: "The server connection is not secure"
    case .unauthorized: "Your session needs to be refreshed"
    case .network: "Could not reach the server"
    case .invalidStream: "The audio stream is unavailable"
    case .unsupportedFormat: "This audio format is unsupported"
    case .media: "Could not play this track"
    case .audioSession: "Audio playback could not start"
    }
}

private func durationText(_ duration: Double) -> String {
    guard duration.isFinite, duration >= 0 else { return "—:—" }
    let seconds = Int(duration.rounded())
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}
