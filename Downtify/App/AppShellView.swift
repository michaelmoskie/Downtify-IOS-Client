import SwiftUI
import Translation

struct AppShellView: View {
    let name: String
    @ObservedObject var presentation: SessionPresentationCoordinator
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    let serverDownloadQueue: ServerDownloadQueue
    let serverDownloads: ServerDownloadPresentationModel
    @AppStorage(DowntifyAppearance.storageKey) private var appearance = DowntifyAppearance.dark
    @AppStorage(DowntifyTheme.storageKey) private var themeJSON = ""
    @AppStorage("downtify.language") private var language = "system"

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
                                connection: presentation.connectionService, serverDownloadQueue: serverDownloadQueue,
                                serverDownloads: serverDownloads,
                                signOut: { try await presentation.connectionService.signOut() })
            }
        }
        .downtifyAppearance(appearance, theme: try? DowntifyTheme.decode(Data(themeJSON.utf8)))
        .environment(\.locale, Locale(identifier: language == "system" ? Locale.current.identifier : language))
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

private extension PlaybackItem {
    var displayTitle: String { title.isEmpty ? String(localized: "Unknown title") : title }
    var displayArtist: String { artist.isEmpty ? String(localized: "Unknown artist") : artist }
    var accessibleMetadata: String {
        album.isEmpty ? String(localized: "\(displayTitle), \(displayArtist)")
            : String(localized: "\(displayTitle), \(displayArtist), \(album)")
    }
}

private struct PlaybackItemArtwork: View {
    let item: PlaybackItem?
    let size: CGFloat

    var body: some View {
        if let track = item?.libraryTrack {
            TrackArtwork(track: track, size: size)
        } else if let url = item?.catalogSong?.coverURL.flatMap(URL.init(string:)),
                  url.scheme?.lowercased() == "https" {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ArtworkPlaceholder(size: size)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
        } else {
            ArtworkPlaceholder(size: size)
        }
    }
}

struct TrackRow: View {
    let track: LibraryTrack
    var isCurrent = false
    var isPlaying = false
    var showsArtwork = true
    var isOnDevice = false
    @Environment(\.downtifyPalette) private var palette

    var body: some View {
        if palette.redesign("library") { redesignRow } else { standardRow }
    }

    /// Compact row: small cover, title, and an on-device / explicit marker before the artist.
    private var redesignRow: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                TrackArtwork(track: track, size: 48).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent { NowPlayingBadge(isPlaying: isPlaying) }
                    Text(track.displayTitle)
                        .font(.body)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if isOnDevice {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(palette.accent)
                            .accessibilityLabel("On this device")
                    }
                    if track.isExplicit {
                        Text(verbatim: "E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(width: 14, height: 14)
                            .background(DowntifyStyle.secondaryText, in: RoundedRectangle(cornerRadius: 2))
                            .accessibilityLabel("Explicit")
                    }
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: DowntifyStyle.minimumControlSize + 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var standardRow: some View {
        DowntifyMediaRow(title: track.displayTitle, subtitle: track.displayArtist,
                         detail: track.album.isEmpty ? nil : track.album,
                         isCurrent: isCurrent, isPlaying: isPlaying) {
            if showsArtwork { TrackArtwork(track: track, size: 56) }
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

extension View {
    /// Shows the playback dock below this tab and publishes its height to the tab's scroll views
    /// (`playbackDockHeight`) so their final rows can scroll clear of it.
    func playbackDock(playback: PlaybackController, library: LibraryPresentationModel,
                      serverDownloads: ServerDownloadPresentationModel) -> some View {
        modifier(PlaybackDockInset(playback: playback, library: library, serverDownloads: serverDownloads))
    }
}

private struct PlaybackDockInset: ViewModifier {
    let playback: PlaybackController
    let library: LibraryPresentationModel
    let serverDownloads: ServerDownloadPresentationModel
    /// Per tab, so a hidden tab's dock appearing or disappearing cannot change the visible tab's clearance.
    @State private var dockHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.playbackDockHeight, dockHeight)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlaybackDock(playback: playback, library: library, serverDownloads: serverDownloads,
                             height: $dockHeight)
            }
    }
}

/// Lives at the navigation boundary so playback updates do not invalidate library rows.
struct PlaybackDock: View {
    @ObservedObject var playback: PlaybackController
    /// Passed through to Now Playing's artist and album pages and its Like and Add to Playlist
    /// actions; not observed here.
    let library: LibraryPresentationModel
    let serverDownloads: ServerDownloadPresentationModel
    /// Measured height of the visible dock; 0 while it is hidden.
    @Binding var height: CGFloat
    @Environment(\.downtifyPalette) private var palette
    @State private var showingNowPlaying = false

    var body: some View {
        Group {
            if playback.podcast != nil || playback.queue.current != nil {
                MiniPlayerView(playback: playback) { showingNowPlaying = true }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, palette.redesign("player") ? DowntifyStyle.Space.small : DowntifyStyle.Space.regular)
                    .padding(.top, DowntifyStyle.Space.small)
                    .padding(.bottom, palette.redesign("player") ? 6 : DowntifyStyle.Space.small)
                    .frame(maxWidth: .infinity)
                    .background {
                        if palette.redesign("player") {
                            // Content fades out under the floating player instead of ending at a hard edge.
                            LinearGradient(colors: [palette.background.opacity(0), palette.background.opacity(0.92)],
                                           startPoint: .top, endPoint: .bottom)
                                .allowsHitTesting(false)
                        } else {
                            palette.background
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { height = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, newHeight in height = newHeight }
                        }
                    }
                    .onDisappear { height = 0 }
                    .accessibilityIdentifier("player.dock")
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(playback: playback, library: library, serverDownloads: serverDownloads)
                .presentationDragIndicator(.visible)
        }
    }
}

private struct MiniPlayerView: View {
    @ObservedObject var playback: PlaybackController
    let open: () -> Void
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @Environment(\.downtifyPalette) private var palette
    /// Cover color behind the redesigned player.
    @State private var tint: Color?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the song info follows the finger; the neighbouring song slides in from the side.
    @State private var dragOffset: CGFloat = 0
    @State private var infoWidth: CGFloat = 0
    @State private var skips = 0

    private var item: PlaybackItem? { playback.queue.current?.item }
    private var isActive: Bool { playback.phase == .playing || playback.phase == .buffering || playback.phase == .loading }
    private var nextID: UUID? { playback.podcast == nil ? playback.queue.next(automatic: false) : nil }
    private var previousID: UUID? { playback.podcast == nil ? playback.queue.previous() : nil }
    private func entryItem(_ id: UUID?) -> PlaybackItem? {
        guard let id else { return nil }
        return playback.queue.order.first { $0.id == id }?.item
    }

    var body: some View {
        if palette.redesign("player") { redesignBody } else { standardBody }
    }

    /// Floating card in the cover's color: swipeable song info, a heart and play/pause, and a thin progress line.
    private var redesignBody: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Button(action: open) {
                ZStack {
                    if dragOffset < 0, let next = entryItem(nextID) {
                        compactInfo(next).offset(x: dragOffset + infoWidth + Self.swipeGap)
                    }
                    if dragOffset > 0, let previous = entryItem(previousID) {
                        compactInfo(previous).offset(x: dragOffset - infoWidth - Self.swipeGap)
                    }
                    currentCompactInfo.offset(x: dragOffset)
                }
                .clipped()
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { infoWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in infoWidth = width }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(swipeGesture)
            .sensoryFeedback(.selection, trigger: skips)
            .accessibilityLabel(nowPlayingLabel)
            .accessibilityHint("Open Now Playing")
            .accessibilityAction(named: Text("Next track")) { playback.skipNext() }
            .accessibilityAction(named: Text("Previous track")) { playback.goToPreviousSong() }
            HStack(spacing: 0) {
                if playback.podcast == nil, let track = item?.libraryTrack, collections.likedIDs != nil {
                    let liked = collections.effectiveLike(track.id)
                    Button { Task { await collections.toggleLike(track) } } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? palette.accent : Color.primary)
                            .downtifyControlTarget()
                    }
                    .disabled(collections.mutationBusy)
                    .accessibilityLabel(liked ? String(localized: "Unlike song") : String(localized: "Like song"))
                    .sensoryFeedback(.selection, trigger: liked)
                }
                if case .failed = playback.phase {
                    Button { playback.play() } label: {
                        Image(systemName: "arrow.clockwise").downtifyControlTarget()
                    }
                    .accessibilityLabel("Retry playback")
                } else {
                    Button { playback.togglePlayback() } label: {
                        Image(systemName: isActive ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .downtifyControlTarget()
                    }
                    .accessibilityLabel(isActive ? String(localized: "Pause") : String(localized: "Play"))
                    .accessibilityIdentifier("player.playPause")
                }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary)
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .background(tint ?? Color(white: 0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            if let duration = playback.duration, duration.isFinite, duration > 0 {
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.white)
                                .frame(width: proxy.size.width * min(max(playback.position / duration, 0), 1))
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)
                .transaction { if reduceMotion { $0.animation = nil } }
            }
        }
        .environment(\.colorScheme, .dark)
        .artworkTint(for: item?.libraryTrack, into: $tint)
    }

    @ViewBuilder
    private var currentCompactInfo: some View {
        if let podcast = playback.podcast {
            compactRow(title: podcast.episode.title, subtitle: podcast.show.name) {
                PodcastArtwork(show: podcast.show, size: 42)
            }
        } else {
            compactInfo(item)
        }
    }

    private func compactInfo(_ item: PlaybackItem?) -> some View {
        compactRow(title: item?.displayTitle ?? "", subtitle: item?.displayArtist ?? "") {
            PlaybackItemArtwork(item: item, size: 42)
        }
    }

    private func compactRow<Artwork: View>(title: String, subtitle: String, @ViewBuilder artwork: () -> Artwork) -> some View {
        HStack(spacing: 10) {
            artwork()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: subtitle)
                    .font(.footnote)
                    .foregroundStyle(DowntifyStyle.secondaryText)
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nowPlayingLabel: String {
        if let podcast = playback.podcast {
            return String(localized: "Now playing, \(podcast.episode.title), \(podcast.show.name)")
        }
        guard let item else { return "" }
        return String(localized: "Now playing, \(item.displayTitle) by \(item.displayArtist)")
    }

    private var standardBody: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            if let podcast = playback.podcast {
                Button(action: open) {
                    DowntifyMediaRow(title: podcast.episode.title, subtitle: podcast.show.name, accessibilityLineLimit: 2) {
                        PodcastArtwork(show: podcast.show, size: 44)
                    } accessory: { EmptyView() }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing, \(podcast.episode.title), \(podcast.show.name)")
                .accessibilityHint("Open Now Playing")
            } else if let item {
                Button(action: open) {
                    ZStack {
                        if dragOffset < 0, let next = entryItem(nextID) {
                            songRow(next).offset(x: dragOffset + infoWidth + Self.swipeGap)
                        }
                        if dragOffset > 0, let previous = entryItem(previousID) {
                            songRow(previous).offset(x: dragOffset - infoWidth - Self.swipeGap)
                        }
                        songRow(item).offset(x: dragOffset)
                    }
                    .clipped()
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { infoWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, width in infoWidth = width }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .highPriorityGesture(swipeGesture)
                .sensoryFeedback(.selection, trigger: skips)
                .accessibilityLabel("Now playing, \(item.displayTitle) by \(item.displayArtist)")
                .accessibilityHint("Open Now Playing")
                .accessibilityAction(named: Text("Next track")) { playback.skipNext() }
                .accessibilityAction(named: Text("Previous track")) { playback.goToPreviousSong() }
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
                    .accessibilityLabel(isActive ? String(localized: "Pause") : String(localized: "Play"))
                    .accessibilityIdentifier("player.playPause")
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
        .background(palette.surface, in: RoundedRectangle(cornerRadius: palette.theme?.playerStyle == "compact" ? 8 : 16))
        .overlay(alignment: .bottom) {
            if let duration = playback.duration, duration.isFinite, duration > 0 {
                ProgressView(value: min(playback.position, duration), total: duration)
                    .padding(.horizontal, 12)
                    .accessibilityHidden(true)
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
        }
    }

    private static let swipeGap: CGFloat = 16

    private func songRow(_ item: PlaybackItem) -> some View {
        DowntifyMediaRow(title: item.displayTitle, subtitle: item.displayArtist, accessibilityLineLimit: 2) {
            PlaybackItemArtwork(item: item, size: 44)
        } accessory: {
            EmptyView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Swipe left for the next song and right for the previous one. The info follows the finger, the
    /// neighbouring song slides in, and a short or slow drag springs back.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard playback.podcast == nil, abs(value.translation.width) > abs(value.translation.height) else { return }
                let dx = value.translation.width
                let hasNeighbour = dx < 0 ? nextID != nil : previousID != nil
                dragOffset = hasNeighbour ? dx : dx * 0.25
            }
            .onEnded { value in
                guard playback.podcast == nil else { return }
                let width = max(infoWidth, 1)
                let dx = value.translation.width
                let flung = value.predictedEndTranslation.width
                if dx < -width * 0.3 || flung < -width * 0.6, nextID != nil {
                    finishSwipe(to: -width - Self.swipeGap) { playback.skipNext() }
                } else if dx > width * 0.3 || flung > width * 0.6, previousID != nil {
                    finishSwipe(to: width + Self.swipeGap) { playback.goToPreviousSong() }
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
    }

    private func finishSwipe(to target: CGFloat, change: @escaping () -> Void) {
        let settle = {
            change()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dragOffset = 0 }
            skips += 1
        }
        if reduceMotion {
            settle()
        } else {
            withAnimation(.easeOut(duration: 0.18)) { dragOffset = target } completion: { settle() }
        }
    }
}

/// Storage for per-track lyric offsets. Defaults to `.standard`; debug harness injects an isolated suite at the root.
private struct LyricDefaultsKey: EnvironmentKey {
    static let defaultValue: UserDefaults = .standard
}

extension EnvironmentValues {
    var lyricDefaults: UserDefaults {
        get { self[LyricDefaultsKey.self] }
        set { self[LyricDefaultsKey.self] = newValue }
    }
}

private struct NowPlayingView: View {
    @ObservedObject var playback: PlaybackController
    let library: LibraryPresentationModel
    let serverDownloads: ServerDownloadPresentationModel
    @State private var path: [NowPlayingRoute] = []
    @State private var artistChoices: [NowPlayingArtistTarget] = []
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var artworkLoader: ArtworkLoader
    @State private var artworkTint: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPlaylistPicker = false
    @State private var confirmation: String?
    @State private var confirmationCount = 0
    @AppStorage("debug.networkOverlay.enabled") private var networkOverlayEnabled = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingQueue = false
    @State private var showingEqualizer = false
    @State private var lyrics: TrackLyrics?
    @State private var lyricsLoading = false
    @State private var lyricsError = false
    @State private var lyricOffset: Double = 0
    @State private var lyricsMode: LyricsDisplayMode = .synced
    @State private var lyricsTrackID: String?
    @StateObject private var translation = LyricsTranslationModel()
    @Environment(\.locale) private var locale
    @Environment(\.lyricDefaults) private var lyricDefaults

    private var item: PlaybackItem? { playback.queue.current?.item }
    private var track: LibraryTrack? { item?.libraryTrack }
    /// The library track behind the current item, including catalog songs already in the library.
    private var actionTrack: LibraryTrack? {
        if let track { return track }
        guard let song = item?.catalogSong else { return nil }
        return library.membership.track(for: song)
    }
    private var upNext: UpNextSummary? { UpNextSummary(queue: playback.queue) }
    private var activelyPlaying: Bool { playback.phase == .playing || playback.phase == .buffering || playback.phase == .loading }

    private var usesWideLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    /// The redesigned player: cover-tinted backdrop, chevron header, inline heart and icon-only actions.
    private var redesign: Bool { palette.redesign("player") }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
            ScrollView {
                let imageSize = redesign ? redesignArtworkSize(for: geometry.size.width) : artworkSize
                let layout = usesWideLayout
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: DowntifyStyle.Space.large))
                    : AnyLayout(VStackLayout(spacing: DowntifyStyle.Space.large))
                layout {
                    Group {
                        if let podcast = playback.podcast {
                            PodcastArtwork(show: podcast.show, size: imageSize)
                        } else {
                            PlaybackItemArtwork(item: item, size: imageSize)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: redesign ? 8 : 0, style: .continuous))
                    .shadow(color: redesign ? .black.opacity(0.4) : .clear, radius: 20, y: 12)
                    .padding(.top, redesign ? DowntifyStyle.Space.small : 0)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("player.artwork")
                    VStack(alignment: redesign ? .leading : .center, spacing: DowntifyStyle.Space.regular) {
                        trackMetadata
                        if !redesign || showsPhase {
                            phaseDescription
                                .font(.subheadline)
                                .foregroundStyle(DowntifyStyle.secondaryText)
                                .multilineTextAlignment(redesign ? .leading : .center)
                                .frame(maxWidth: redesign ? .infinity : nil, alignment: .leading)
                        }
                        timeline
                        transportControls
                        if playback.podcast == nil {
                            if redesign { redesignActionRow } else {
                                actionRow
                                queueControls
                            }
                            upNextCard
                            if track != nil { lyricsSection }
                        } else {
                            if playback.podcastProgressSaveFailed {
                                Text("Could not save playback progress to the server.")
                                    .font(.footnote)
                                    .foregroundStyle(DowntifyStyle.error)
                            }
                            if item != nil {
                                if redesign {
                                    Button("Back to music", systemImage: "music.note") { playback.returnToMusic() }
                                        .buttonStyle(.bordered)
                                } else {
                                    Button("Back to music", systemImage: "music.note") { playback.returnToMusic() }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: redesign && !usesWideLayout ? 520 : 400)
                }
                .padding(.horizontal, redesign ? DowntifyStyle.Space.large : DowntifyStyle.Space.regular)
                .padding(.top, redesign ? 0 : DowntifyStyle.Space.regular)
                .padding(.bottom, redesign ? DowntifyStyle.Space.large : DowntifyStyle.Space.regular)
                .frame(maxWidth: redesign ? 820 : 760)
                .frame(maxWidth: .infinity)
            }
            }
            if networkOverlayEnabled {
                NetworkDebugOverlayContainer(playback: playback)
            }
            }
            .overlay(alignment: .bottom) { confirmationBanner }
            .background {
                if redesign {
                    LinearGradient(colors: [artworkTint ?? Color(white: 0.28), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                } else { palette.background.ignoresSafeArea() }
            }
            .navigationTitle("Now Playing")
            .accessibilityIdentifier("player.full")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(redesign ? .hidden : .automatic, for: .navigationBar)
            .toolbarBackground(palette.background, for: .navigationBar)
            .toolbar {
                if redesign {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Done")
                        .accessibilityIdentifier("player.close")
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(playback.podcast == nil ? "Playing from your library" : "Playing podcast")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DowntifyStyle.secondaryText)
                                .textCase(.uppercase)
                            Text(verbatim: playback.podcast?.show.name
                                 ?? (item?.album.isEmpty == false ? item?.album ?? "" : item?.displayArtist ?? ""))
                                .font(.footnote.weight(.bold))
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: NowPlayingRoute.self) { route in
                Group {
                    switch route {
                    case .artist(let target):
                        NowPlayingArtistPage(target: target, library: library, playback: playback,
                                             serverDownloads: serverDownloads)
                    case .album(let target):
                        NowPlayingAlbumPage(target: target, library: library, playback: playback,
                                            serverDownloads: serverDownloads)
                    }
                }
                .background(palette.background.ignoresSafeArea())
                .toolbarBackground(palette.background, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .confirmationDialog("Go to artist", isPresented: Binding(get: { !artistChoices.isEmpty },
                                                                     set: { if !$0 { artistChoices = [] } }),
                                titleVisibility: .visible) {
                ForEach(artistChoices, id: \.self) { target in
                    Button(target.name) { path.append(.artist(target)) }
                }
            }
        }
        .sheet(isPresented: $showingQueue) {
            PlaybackQueueSheet(playback: playback)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEqualizer) {
            NavigationStack { EqualizerView(playback: playback, showsDoneButton: true) }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            if let actionTrack {
                AddToPlaylistSheet(track: actionTrack) { title in
                    showConfirmation(String(localized: "Added to \(title)"))
                }
                .presentationDragIndicator(.visible)
                .presentationDetents([.medium, .large])
            }
        }
        .sensoryFeedback(.success, trigger: confirmationCount)
        .task(id: confirmationCount) {
            guard confirmation != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut) { confirmation = nil }
        }
        .artworkTint(for: redesign ? track : nil, into: $artworkTint)
        .task(id: track?.id) { await loadLyrics() }
        .modifier(LyricsTranslationSupport(model: translation))
        .environment(\.colorScheme, redesign ? .dark : colorScheme)
    }

    @ViewBuilder
    private var trackMetadata: some View {
        if playback.podcast == nil, let item {
            musicMetadata(item)
        } else {
            VStack(alignment: redesign ? .leading : .center, spacing: redesign ? 4 : 5) {
                Text(playback.podcast?.episode.title ?? item?.displayTitle ?? String(localized: "Unknown title"))
                    .font(.title2.weight(.bold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .accessibilityAddTraits(.isHeader)
                Text(playback.podcast?.show.name ?? item?.displayArtist ?? String(localized: "Unknown artist"))
                    .font(redesign ? .body : .title3)
                    .foregroundStyle(DowntifyStyle.secondaryText)
                if let album = playback.podcast?.show.author, !album.isEmpty {
                    Text(album)
                        .font(.subheadline)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                }
            }
            .multilineTextAlignment(redesign ? .leading : .center)
            .frame(maxWidth: redesign ? .infinity : nil, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    /// Title and album open the album page, the artist opens the artist page.
    /// Targets resolve at tap time so this sheet never observes the library.
    @ViewBuilder
    private func musicMetadata(_ item: PlaybackItem) -> some View {
        if redesign { redesignMetadata(item) } else { standardMetadata(item) }
    }

    /// Title, artist and album on the left and the heart on the right.
    private func redesignMetadata(_ item: PlaybackItem) -> some View {
        let hasAlbum = !item.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasArtist = !item.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || item.artists.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let like = likePresentation
        return HStack(alignment: .center, spacing: DowntifyStyle.Space.regular) {
            VStack(alignment: .leading, spacing: 4) {
                Button { openAlbum(item) } label: {
                    Text(item.displayTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                .disabled(!hasAlbum)
                .accessibilityLabel(item.displayTitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(hasAlbum ? String(localized: "Opens the album page") : "")
                .accessibilityIdentifier("player.title")
                Button { openArtist(item) } label: {
                    Text(item.displayArtist)
                        .font(.body)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                }
                .disabled(!hasArtist)
                .accessibilityLabel("Artist, \(item.displayArtist)")
                .accessibilityHint(hasArtist ? String(localized: "Opens the artist page") : "")
                .accessibilityIdentifier("player.artist")
                if hasAlbum {
                    Button { openAlbum(item) } label: {
                        Text(item.album)
                            .font(.footnote)
                            .foregroundStyle(DowntifyStyle.secondaryText)
                            .lineLimit(1)
                    }
                    .accessibilityLabel("Album, \(item.album)")
                    .accessibilityHint("Opens the album page")
                    .accessibilityIdentifier("player.album")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard let actionTrack else { return }
                Task { await collections.toggleLike(actionTrack) }
            } label: {
                Image(systemName: like.isLiked ? "heart.fill" : "heart")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(like.isLiked ? palette.accent : Color.primary)
                    .overlay(alignment: .topTrailing) {
                        if like.isPending {
                            Image(systemName: "clock.fill").font(.caption2).offset(x: 8, y: -6)
                        }
                    }
                    .downtifyControlTarget()
            }
            .disabled(!like.isEnabled)
            .accessibilityLabel(Text(verbatim: like.accessibilityLabel))
            .accessibilityValue(like.isPending ? String(localized: "Queued") : "")
            .accessibilityHint(Text(verbatim: like.explanation ?? ""))
            .accessibilityIdentifier("player.like")
            .sensoryFeedback(.selection, trigger: like.isLiked)
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func standardMetadata(_ item: PlaybackItem) -> some View {
        let hasAlbum = !item.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasArtist = !item.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || item.artists.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return VStack(alignment: palette.redesign("player") ? .leading : .center, spacing: 5) {
            Button { openAlbum(item) } label: {
                Text(item.displayTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            .disabled(!hasAlbum)
            .accessibilityLabel(item.displayTitle)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(hasAlbum ? String(localized: "Opens the album page") : "")
            .accessibilityIdentifier("player.title")
            Button { openArtist(item) } label: {
                Text(item.displayArtist)
                    .font(.title3)
                    .foregroundStyle(palette.redesign("player") ? DowntifyStyle.secondaryText : (hasArtist ? palette.accent : DowntifyStyle.secondaryText))
            }
            .disabled(!hasArtist)
            .accessibilityLabel("Artist, \(item.displayArtist)")
            .accessibilityHint(hasArtist ? String(localized: "Opens the artist page") : "")
            .accessibilityIdentifier("player.artist")
            if hasAlbum {
                Button { openAlbum(item) } label: {
                    Text(item.album)
                        .font(.subheadline)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                        .underline()
                }
                .accessibilityLabel("Album, \(item.album)")
                .accessibilityHint("Opens the album page")
                .accessibilityIdentifier("player.album")
            }
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(palette.redesign("player") ? .leading : .center)
        .frame(maxWidth: .infinity, alignment: palette.redesign("player") ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openAlbum(_ item: PlaybackItem) {
        guard let target = NowPlayingNavigationResolver.albumTarget(for: item, catalog: library.catalog) else { return }
        path.append(.album(target))
    }

    private func openArtist(_ item: PlaybackItem) {
        let targets = NowPlayingNavigationResolver.artistTargets(for: item, catalog: library.catalog)
        if targets.count == 1 {
            path.append(.artist(targets[0]))
        } else if targets.count > 1 {
            artistChoices = targets
        }
    }

    @ViewBuilder
    private var transportControls: some View {
        if redesign { redesignTransportControls } else { standardTransportControls }
    }

    /// Shuffle, previous, a large white play/pause, next and repeat across the full width.
    private var redesignTransportControls: some View {
        HStack(spacing: 0) {
            if playback.podcast == nil {
                shuffleButton
                Spacer(minLength: 4)
            }
            if playback.podcast != nil {
                Button { playback.seek(to: playback.position - 15) } label: {
                    Image(systemName: "gobackward.15").font(.title).downtifyControlTarget()
                }
                .accessibilityLabel("Back 15 seconds")
            } else {
                Button { playback.skipPrevious() } label: {
                    Image(systemName: "backward.end.fill").font(.title)
                        .downtifyControlTarget()
                }
                .accessibilityLabel("Previous track")
                .disabled(item == nil)
            }
            Spacer(minLength: 4)
            if case .failed = playback.phase {
                Button { playback.play() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 68, height: 68)
                        .background(Color.white, in: Circle())
                }
                .accessibilityLabel("Retry playback")
            } else {
                Button { playback.togglePlayback() } label: {
                    Image(systemName: activelyPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: activelyPlaying ? 0 : 2)
                        .frame(width: 68, height: 68)
                        .background(Color.white, in: Circle())
                }
                .accessibilityLabel(activelyPlaying ? String(localized: "Pause") : String(localized: "Play"))
                .accessibilityIdentifier("player.playPause")
                .disabled(item == nil && playback.podcast == nil)
            }
            Spacer(minLength: 4)
            if playback.podcast != nil {
                Button { playback.seek(to: playback.position + 30) } label: {
                    Image(systemName: "goforward.30").font(.title).downtifyControlTarget()
                }
                .accessibilityLabel("Forward 30 seconds")
            } else {
                Button { playback.skipNext() } label: {
                    Image(systemName: "forward.end.fill").font(.title)
                        .downtifyControlTarget()
                }
                .accessibilityLabel("Next track")
                .accessibilityValue(nextTrackValue)
                .disabled(playback.queue.next(automatic: false) == nil)
            }
            if playback.podcast == nil {
                Spacer(minLength: 4)
                repeatButton
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
    }

    /// Accent color with a dot underneath while on, as in most music apps.
    private func modeIndicator(_ isOn: Bool) -> some View {
        Circle().fill(isOn ? palette.accent : .clear).frame(width: 4, height: 4)
    }

    private var shuffleButton: some View {
        let isOn = playback.queue.shuffledIDs != nil
        return Button { playback.setShuffle(!isOn) } label: {
            VStack(spacing: 3) {
                Image(systemName: "shuffle").font(.title3.weight(.semibold))
                modeIndicator(isOn)
            }
            .foregroundStyle(isOn ? palette.accent : Color.primary)
            .downtifyControlTarget()
        }
        .accessibilityLabel("Shuffle")
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var repeatButton: some View {
        let isOn = playback.queue.repeatMode != .off
        return Button { playback.setRepeat(nextRepeatMode) } label: {
            VStack(spacing: 3) {
                Image(systemName: repeatSymbol).font(.title3.weight(.semibold))
                modeIndicator(isOn)
            }
            .foregroundStyle(isOn ? palette.accent : Color.primary)
            .downtifyControlTarget()
        }
        .accessibilityLabel("Repeat")
        .accessibilityValue(repeatDescription)
        .accessibilityHint("Changes repeat mode")
    }

    private var standardTransportControls: some View {
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
                .disabled(item == nil)
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
                .accessibilityLabel(activelyPlaying ? String(localized: "Pause") : String(localized: "Play"))
                .accessibilityIdentifier("player.playPause")
                .disabled(item == nil && playback.podcast == nil)
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
                .accessibilityValue(nextTrackValue)
                .disabled(playback.queue.next(automatic: false) == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderless)
    }

    private var nextTrackValue: String {
        guard let title = upNext?.entry.item.displayTitle else { return "" }
        return String(localized: "Next track: \(title)")
    }

    private var queueControls: some View {
        HStack(spacing: DowntifyStyle.Space.regular) {
            Button { playback.setShuffle(playback.queue.shuffledIDs == nil) } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.queue.shuffledIDs == nil ? DowntifyStyle.secondaryText : palette.accent)
                    .downtifyControlTarget()
                    .background {
                        if playback.queue.shuffledIDs != nil {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent)
                        }
                    }
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.queue.shuffledIDs == nil ? String(localized: "Off") : String(localized: "On"))
            .accessibilityAddTraits(playback.queue.shuffledIDs == nil ? [] : .isSelected)

            Button { playback.setRepeat(nextRepeatMode) } label: {
                Image(systemName: repeatSymbol)
                    .foregroundStyle(playback.queue.repeatMode == .off ? DowntifyStyle.secondaryText : palette.accent)
                    .downtifyControlTarget()
                    .background {
                        if playback.queue.repeatMode != .off {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent)
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

    private var likePresentation: NowPlayingLikePresentation {
        NowPlayingLikePresentation.make(
            itemTitle: item?.displayTitle ?? "", isInLibrary: actionTrack != nil,
            likesAvailable: collections.likedIDs != nil,
            liked: actionTrack.map { collections.effectiveLike($0.id) } ?? false,
            pending: actionTrack.map { collections.hasPendingLike($0.id) } ?? false,
            busy: collections.mutationBusy)
    }

    private var playlistPresentation: NowPlayingPlaylistPresentation {
        NowPlayingPlaylistPresentation.make(
            itemTitle: item?.displayTitle ?? "", isInLibrary: actionTrack != nil,
            supportsEditing: collections.supportsPlaylistEditing,
            editablePlaylistCount: EditablePlaylists.sorted(
                collections.playlists, supportsEditing: collections.supportsPlaylistEditing).count,
            busy: collections.mutationBusy)
    }

    /// Labeled actions so Like, Add to Playlist and the queue are visible without guessing at icons.
    private var actionRow: some View {
        let like = likePresentation
        let playlist = playlistPresentation
        var explanations: [String] = []
        for explanation in [like.explanation, playlist.explanation].compactMap({ $0 }) where !explanations.contains(explanation) {
            explanations.append(explanation)
        }
        return VStack(spacing: DowntifyStyle.Space.small) {
            HStack(alignment: .top, spacing: DowntifyStyle.Space.small) {
                NowPlayingActionButton(title: like.title, systemImage: like.systemImage,
                                       isHighlighted: like.isLiked, showsPending: like.isPending) {
                    guard let actionTrack else { return }
                    Task { await collections.toggleLike(actionTrack) }
                }
                .disabled(!like.isEnabled)
                .accessibilityLabel(Text(verbatim: like.accessibilityLabel))
                .accessibilityValue(like.isPending ? String(localized: "Queued") : "")
                .accessibilityHint(Text(verbatim: like.explanation ?? ""))
                .accessibilityIdentifier("player.like")
                .sensoryFeedback(.selection, trigger: like.isLiked)

                NowPlayingActionButton(title: String(localized: "Add to Playlist"), systemImage: "text.badge.plus") {
                    showingPlaylistPicker = true
                }
                .disabled(!playlist.isEnabled)
                .accessibilityLabel(Text(verbatim: playlist.accessibilityLabel))
                .accessibilityHint(Text(verbatim: playlist.explanation ?? ""))
                .accessibilityIdentifier("player.addToPlaylist")

                NowPlayingActionButton(title: String(localized: "Queue"), systemImage: "list.bullet") {
                    showingQueue = true
                }
                .accessibilityHint("Open queue")
                .accessibilityIdentifier("player.queue")
            }
            if !explanations.isEmpty {
                Text(verbatim: explanations.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(DowntifyStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Add to Playlist on the left and the queue on the right, below the transport controls.
    private var redesignActionRow: some View {
        let playlist = playlistPresentation
        let like = likePresentation
        var explanations: [String] = []
        for explanation in [like.explanation, playlist.explanation].compactMap({ $0 }) where !explanations.contains(explanation) {
            explanations.append(explanation)
        }
        return VStack(spacing: DowntifyStyle.Space.small) {
            HStack {
                Button { showingPlaylistPicker = true } label: {
                    Image(systemName: "plus.circle").font(.title2).downtifyControlTarget()
                }
                .disabled(!playlist.isEnabled)
                .accessibilityLabel(Text(verbatim: playlist.accessibilityLabel))
                .accessibilityHint(Text(verbatim: playlist.explanation ?? ""))
                .accessibilityIdentifier("player.addToPlaylist")
                Spacer()
                Button { showingQueue = true } label: {
                    Image(systemName: "list.bullet").font(.title2).downtifyControlTarget()
                }
                .accessibilityLabel("Queue")
                .accessibilityHint("Open queue")
                .accessibilityIdentifier("player.queue")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary)
            if !explanations.isEmpty {
                Text(verbatim: explanations.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(DowntifyStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Album, artist, playlist, queue and equalizer shortcuts in one place.
    private var moreMenu: some View {
        Menu {
            if let item, playback.podcast == nil {
                Button("Add to Playlist", systemImage: "text.badge.plus") { showingPlaylistPicker = true }
                    .disabled(!playlistPresentation.isEnabled)
                if !item.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Go to album", systemImage: "opticaldisc") { openAlbum(item) }
                }
                Button("Go to artist", systemImage: "music.mic") { openArtist(item) }
                Button("Queue", systemImage: "list.bullet") { showingQueue = true }
            }
            Button("Equalizer", systemImage: "slider.vertical.3") { showingEqualizer = true }
                .accessibilityIdentifier("player.equalizer")
            if playback.podcast != nil, item != nil {
                Button("Back to music", systemImage: "music.note") { playback.returnToMusic() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold))
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("player.more")
    }

    /// Playing and paused are obvious from the controls; only loading, buffering and errors get a line.
    private var showsPhase: Bool {
        switch playback.phase {
        case .playing, .paused, .idle: false
        default: true
        }
    }

    /// Shows what plays next; tapping opens the full queue.
    private var upNextCard: some View {
        Button { showingQueue = true } label: {
            HStack(spacing: DowntifyStyle.Space.small) {
                VStack(alignment: .leading, spacing: DowntifyStyle.Space.small) {
                    Text("Up Next")
                        .font(.headline)
                    if let upNext {
                        DowntifyMediaRow(title: upNext.entry.item.displayTitle, subtitle: upNext.entry.item.displayArtist,
                                         accessibilityLineLimit: 2) {
                            PlaybackItemArtwork(item: upNext.entry.item, size: 44)
                        } accessory: { EmptyView() }
                        if upNext.wrapsToStart {
                            Text("Then back to the start")
                                .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                        } else if upNext.laterCount > 0 {
                            Text("\(Int(upNext.laterCount)) more in queue")
                                .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                        }
                    } else if autoplayContinues {
                        Label {
                            Text("Autoplay will continue with similar songs")
                                .foregroundStyle(DowntifyStyle.secondaryText)
                        } icon: {
                            Image(systemName: "infinity").foregroundStyle(palette.accent)
                        }
                        .font(.subheadline)
                    } else {
                        Text("Nothing up next")
                            .font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DowntifyStyle.secondaryText)
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(redesign ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(palette.surface),
                        in: RoundedRectangle(cornerRadius: redesign ? 12 : 18))
            .contentShape(RoundedRectangle(cornerRadius: redesign ? 12 : 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: upNextAccessibilityLabel))
        .accessibilityHint("Open queue")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("player.upNext")
    }

    /// Autoplay will add similar songs to follow this, the last song in the queue. Once playback has ended,
    /// Autoplay found nothing to add.
    private var autoplayContinues: Bool {
        playback.autoplay && playback.queue.repeatMode == .off && playback.podcast == nil && playback.phase != .ended
    }

    private var upNextAccessibilityLabel: String {
        guard let entry = upNext?.entry else {
            return autoplayContinues ? String(localized: "Autoplay will continue with similar songs")
                : String(localized: "Nothing up next")
        }
        let title = entry.item.displayTitle
        let artist = entry.item.displayArtist
        return String(localized: "Up Next: \(title) by \(artist)")
    }

    @ViewBuilder
    private var confirmationBanner: some View {
        if let confirmation {
            Label { Text(verbatim: confirmation) } icon: { Image(systemName: "checkmark.circle.fill") }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, DowntifyStyle.Space.regular)
                .padding(.vertical, DowntifyStyle.Space.small)
                .background(palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.accent.opacity(0.4)))
                .padding(.bottom, DowntifyStyle.Space.large)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.confirmation")
        }
    }

    private func showConfirmation(_ message: String) {
        withAnimation(reduceMotion ? nil : .spring) { confirmation = message }
        confirmationCount += 1
        AccessibilityNotification.Announcement(message).post()
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

    /// The cover fills the width (up to 420 pt) on phones; fixed beside the controls on wide layouts.
    private func redesignArtworkSize(for width: CGFloat) -> CGFloat {
        if usesWideLayout { return 300 }
        let available = max(160, width - DowntifyStyle.Space.large * 2)
        return dynamicTypeSize.isAccessibilitySize ? min(available, 200) : min(available, 420)
    }

    private var lyricsSection: some View {
        let mode = LyricsPresentation.effectiveMode(lyrics, requested: lyricsMode)
        return VStack(alignment: .leading, spacing: DowntifyStyle.Space.small) {
            HStack {
                Label("Lyrics", systemImage: "quote.bubble")
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if mode == .synced {
                    HStack(spacing: 4) {
                        Button { setLyricOffset(lyricOffset - LyricsPresentation.offsetStep) } label: {
                            Image(systemName: "minus").downtifyControlTarget()
                        }.accessibilityLabel("Lyrics earlier by half a second")
                        Text("\(lyricOffset, format: .number.precision(.fractionLength(1)))s")
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityIdentifier("lyrics.offsetValue")
                            .accessibilityLabel("Lyrics offset \(lyricOffset, format: .number.precision(.fractionLength(1))) seconds")
                        Button { setLyricOffset(lyricOffset + LyricsPresentation.offsetStep) } label: {
                            Image(systemName: "plus").downtifyControlTarget()
                        }.accessibilityLabel("Lyrics later by half a second")
                        Button { resetLyricOffset() } label: {
                            Image(systemName: "arrow.counterclockwise").downtifyControlTarget()
                        }
                        .disabled(lyricOffset == 0)
                        .accessibilityIdentifier("lyrics.resetOffset")
                        .accessibilityLabel("Reset lyrics timing")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !lyricsLoading { translationControls }
            if lyricsLoading {
                ProgressView("Loading lyrics…")
            } else if let lyrics, let mode {
                if LyricsPresentation.offersModeChoice(lyrics) {
                    Picker("Lyrics display", selection: $lyricsMode) {
                        Text("Synced").tag(LyricsDisplayMode.synced)
                        Text("Static").tag(LyricsDisplayMode.static)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("lyrics.modePicker")
                    .accessibilityLabel("Lyrics display")
                }
                if mode == .synced {
                    let lines = lyrics.lines
                    let active = LyricsPresentation.activeIndex(lines, position: playback.position, offset: lyricOffset)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(displayedLines(for: lyrics).enumerated()), id: \.offset) { index, line in
                            Button { seekToLyric(line) } label: {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(redesign || index == active ? .title3.weight(.bold) : .body)
                                    .foregroundStyle(redesign
                                                     ? (index == active ? Color.primary : Color.black.opacity(0.55))
                                                     : (index == active ? palette.accent : DowntifyStyle.secondaryText))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("lyrics.line.\(index)")
                            .accessibilityLabel("Seek to \(spokenLine(line)) at \(LyricsPresentation.accessibilityTime(line.time))")
                            .accessibilityHint("Jumps playback to this line")
                            .accessibilityAddTraits(index == active ? .isSelected : [])
                        }
                    }
                    .accessibilityElement(children: .contain)
                } else {
                    Text(displayedPlain(for: lyrics))
                        .font(redesign ? .title3.weight(.semibold) : .body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lyrics.plain")
                        .accessibilityLabel("Plain lyrics")
                }
            } else {
                Text(lyricsError ? String(localized: "Lyrics could not be loaded.") : String(localized: "Lyrics are unavailable for this track."))
                    .font(.subheadline)
                    .foregroundStyle(DowntifyStyle.secondaryText)
                if lyricsError {
                    Button("Retry") { Task { await loadLyrics() } }
                }
            }
        }
        .padding(DowntifyStyle.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if redesign {
                // The lyrics card takes the cover color, a little lighter than the backdrop.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(artworkTint ?? Color(white: 0.3))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12)))
            } else {
                RoundedRectangle(cornerRadius: 18).fill(palette.surface)
            }
        }
    }

    @ViewBuilder
    private var translationControls: some View {
        switch translation.phase {
        case .ready:
            Button { translation.requestTranslation() } label: {
                Label("Translate", systemImage: "translate")
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHint("Shows the lyrics in your device language")
        case .translating:
            ProgressView("Translating lyrics…")
        case .translated(let result):
            VStack(alignment: .leading, spacing: 4) {
                Button { translation.showOriginal() } label: {
                    Label("Show original", systemImage: "text.quote")
                }
                .buttonStyle(.borderless)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint("Shows the lyrics in their original language")
                if let code = result.sourceLanguage?.languageCode?.identifier,
                   let name = locale.localizedString(forLanguageCode: code) {
                    Text("Translated from \(name)")
                        .font(.footnote)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                }
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                if failure == .unsupported {
                    Text("Translation is not available for these lyrics.")
                        .font(.footnote)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                } else {
                    Text("Lyrics could not be translated.")
                        .font(.footnote)
                        .foregroundStyle(DowntifyStyle.secondaryText)
                    Button("Retry") { translation.requestTranslation() }
                        .buttonStyle(.borderless)
                }
            }
        case .hidden, .sameLanguage, .unsupported:
            EmptyView()
        }
    }

    /// Translated lines mirror the original lines one to one, so highlighting and seeking keep the original timestamps.
    private func displayedLines(for lyrics: TrackLyrics) -> [LyricLine] {
        if case .translated(let result) = translation.phase, case .timed(let lines) = result.content,
           lines.count == lyrics.lines.count { return lines }
        return lyrics.lines
    }

    /// Static view: translated plain text, or the translated synced lines joined when only those were translated.
    private func displayedPlain(for lyrics: TrackLyrics) -> String {
        guard case .translated(let result) = translation.phase else { return lyrics.plain }
        switch result.content {
        case .plain(let text): return text
        case .timed(let lines): return lines.map(\.text).joined(separator: "\n")
        }
    }

    /// The device's preferred language, not the in-app language override.
    private static var systemTranslationTarget: Locale.Language? {
        Locale.preferredLanguages.first.map { Locale.Language(identifier: $0) }
    }

    private func loadLyrics() async {
        translation.configure(defaults: lyricDefaults)
        translation.load(trackID: nil, lyrics: nil, target: nil)
        guard let track else { lyrics = nil; lyricsTrackID = nil; return }
        lyricsLoading = true
        lyricsError = false
        lyrics = nil
        lyricsTrackID = nil
        lyricsMode = .synced
        lyricOffset = LyricsPresentation.savedOffset(in: lyricDefaults, key: playback.lyricsOffsetKey(trackID: track.id))
        defer { if !Task.isCancelled { lyricsLoading = false } }
        do {
            let loaded = try await playback.lyrics(for: track.id)
            guard !Task.isCancelled else { return }
            lyrics = loaded
            lyricsTrackID = track.id
            translation.load(trackID: track.id, lyrics: loaded, target: Self.systemTranslationTarget)
        } catch {
            if !Task.isCancelled { lyricsError = true; lyrics = nil }
        }
    }

    private func setLyricOffset(_ value: Double) {
        lyricOffset = LyricsPresentation.clampedOffset(value)
        if let track { lyricDefaults.set(lyricOffset, forKey: playback.lyricsOffsetKey(trackID: track.id)) }
    }

    private func spokenLine(_ line: LyricLine) -> String {
        line.text.isEmpty ? String(localized: "instrumental break") : line.text
    }

    private func resetLyricOffset() {
        lyricOffset = 0
        if let track { LyricsPresentation.resetOffset(in: lyricDefaults, key: playback.lyricsOffsetKey(trackID: track.id)) }
    }

    /// Seeks so the tapped line becomes the active line. Ignored if the lines belong to a previous track.
    private func seekToLyric(_ line: LyricLine) {
        guard let track, lyricsTrackID == track.id else { return }
        playback.seek(to: LyricsPresentation.seekTarget(for: line, offset: lyricOffset, duration: playback.duration))
    }

    @ViewBuilder
    private var phaseDescription: some View {
        switch playback.phase {
        case .idle: Text("Ready")
        case .loading: Label(playback.podcast == nil ? String(localized: "Loading track") : String(localized: "Loading episode"), systemImage: "hourglass")
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
        VStack(spacing: redesign ? 2 : 5) {
            if let duration = playback.duration, duration.isFinite, duration > 0 {
                Group {
                    if redesign {
                        DowntifyScrubber(value: min(playback.position, duration), total: duration,
                                         onChange: { playback.seek(to: $0, checkpoint: false) },
                                         onEditingChanged: { if !$0 { playback.finishScrubbing() } })
                    } else {
                        Slider(value: Binding(get: { min(playback.position, duration) }, set: { playback.seek(to: $0, checkpoint: false) }),
                               in: 0...duration, onEditingChanged: { if !$0 { playback.finishScrubbing() } })
                    }
                }
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

/// Icon over a short label; keeps the 44 pt target and wraps at large Dynamic Type sizes.
private struct NowPlayingActionButton: View {
    @Environment(\.downtifyPalette) private var palette
    let title: String
    let systemImage: String
    var isHighlighted = false
    var showsPending = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 28)
                    .overlay(alignment: .topTrailing) {
                        if showsPending {
                            Image(systemName: "clock.fill")
                                .font(.caption2)
                                .offset(x: 8, y: -6)
                        }
                    }
                Text(verbatim: title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isHighlighted ? palette.accent : (isEnabled ? Color.primary : DowntifyStyle.secondaryText))
            .frame(maxWidth: .infinity, minHeight: DowntifyStyle.minimumControlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

private struct PlaybackQueueSheet: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: QueueDrag?
    /// Vertical finger travel since the lift.
    @State private var dragOffset: CGFloat = 0
    /// Global frames: named coordinate spaces report rows inside a lazy stack inconsistently.
    @State private var rowFrames: [UUID: CGRect] = [:]

    /// A stack, not a List: List cells clip rows that slide out of them and end the drag gesture
    /// when the dragged row's cell moves, so live reflow needs plain views.
    private var cardRadius: CGFloat { palette.redesign("queue") ? CGFloat(palette.theme?.cardCornerRadius ?? 10) : 10 }

    private var visibleEntries: [PlaybackQueueEntry] {
        guard let currentIndex = playback.queue.currentIndex else { return [] }
        return Array(playback.queue.order.dropFirst(currentIndex))
    }

    private var upcomingEntries: [PlaybackQueueEntry] { Array(visibleEntries.dropFirst()) }

    /// Live placement of the dragged row: its centre, moved by the finger, against the rows captured at lift.
    private var placement: QueueDragPlacement? {
        guard let drag else { return nil }
        return QueueDragPlacement(midYs: drag.midYs, rowHeights: drag.rowHeights, from: drag.from,
                                  dragY: drag.midYs[drag.from] + dragOffset)
    }

    private var reflowAnimation: Animation? { reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.1) }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if visibleEntries.isEmpty {
                        DowntifyUnavailableView(title: "Queue is empty", symbol: "music.note.list")
                            .padding(.vertical, DowntifyStyle.Space.large)
                            .frame(maxWidth: .infinity)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: cardRadius))
                    } else {
                        VStack(spacing: DowntifyStyle.Space.regular) {
                            queueCard
                            if playback.podcast == nil { autoplayCard }
                        }
                    }
                }
                .padding(.horizontal, DowntifyStyle.Space.regular)
                .padding(.vertical, DowntifyStyle.Space.small)
            }
            .onPreferenceChange(QueueRowFramesKey.self) { rowFrames = $0 }
            .onChange(of: upcomingEntries.map(\.id)) { _, ids in
                // The queue changed under the finger (track advanced, removal, Play next): drop the drag unapplied.
                if let drag, drag.entryIDs != ids { self.drag = nil; dragOffset = 0 }
            }
            .scrollDisabled(drag != nil)
            .background(palette.background.ignoresSafeArea())
            .toolbarBackground(palette.background, for: .navigationBar)
            .navigationTitle("Play Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.selection, trigger: placement?.target)
        }
    }

    /// Rows on one rounded surface with inset separators, matching the grouped list used elsewhere.
    private var queueCard: some View {
        LazyVStack(spacing: 0) {
            if let current = visibleEntries.first {
                QueueEntryRow(entry: current, isCurrent: true, playback: playback)
                    .modifier(QueueRowChrome(showsSeparator: !upcomingEntries.isEmpty))
            }
            ForEach(Array(upcomingEntries.enumerated()), id: \.element.id) { offset, entry in
                let isDragged = drag?.id == entry.id
                QueueEntryRow(
                    entry: entry, isCurrent: false, playback: playback,
                    reorder: QueueReorder(
                        position: offset, count: upcomingEntries.count,
                        move: { target in
                            playback.moveUpcoming(entry.id, toUpcomingOffset: target)
                            AccessibilityNotification.Announcement(
                                String(localized: "Moved to position \(Int(target + 1)) of \(Int(upcomingEntries.count))")).post()
                        },
                        dragChanged: { translation in
                            beginDragIfNeeded(of: entry.id)
                            dragOffset = translation
                        },
                        dragEnded: { translation in
                            dragOffset = translation
                            commitDrag(of: entry.id)
                        },
                        dragCancelled: { cancelDragIfStale(of: entry.id) }))
                    .modifier(QueueRowChrome(showsSeparator: offset < upcomingEntries.count - 1))
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: QueueRowFramesKey.self,
                                               value: [entry.id: proxy.frame(in: .global)])
                    })
                    // The lifted copy in the card overlay stands in for the dragged row (it keeps the gesture);
                    // the others slide, animated, to open a gap at the target.
                    .opacity(isDragged ? 0 : 1)
                    .offset(y: isDragged ? 0 : placement?.offset(for: offset) ?? 0)
                    .animation(reflowAnimation, value: placement?.target)
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        // Drawn above the stack because a lazy stack does not honour zIndex between its rows.
        .overlay { GeometryReader { proxy in liftedRow(cardOrigin: proxy.frame(in: .global).origin) } }
    }

    /// After the last song: whether Autoplay will continue with similar songs, with a switch for it.
    private var autoplayCard: some View {
        HStack(spacing: DowntifyStyle.Space.regular) {
            Image(systemName: "infinity")
                .font(.body.weight(.semibold))
                .foregroundStyle(playback.autoplay ? palette.accent : DowntifyStyle.secondaryText)
                .frame(width: 32, height: 32)
                .background(palette.elevated, in: Circle())
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { playback.autoplay }, set: { playback.setAutoplay($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autoplay").font(.body.weight(.semibold))
                    Text(playback.queue.repeatMode != .off ? "Paused while repeat is on."
                         : "When your music ends, keep playing similar songs.")
                        .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(palette.brand)
        }
        .padding(palette.cardPadding(default: DowntifyStyle.Space.regular))
        .background(palette.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .accessibilityIdentifier("queue.autoplay")
    }

    /// The dragged row, raised and following the finger 1:1.
    @ViewBuilder private func liftedRow(cardOrigin: CGPoint) -> some View {
        if let drag {
            QueueEntryRow(entry: drag.entry, isCurrent: false, playback: playback, isLifted: true)
                .modifier(QueueRowChrome(showsSeparator: false))
                .frame(width: drag.frame.width, height: drag.frame.height)
                .background {
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .fill(palette.surface)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                }
                .scaleEffect(1.03)
                .offset(x: drag.frame.minX - cardOrigin.x, y: drag.frame.minY - cardOrigin.y + dragOffset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Captures row geometry once, so rows reflowing under the finger do not feed back into the placement.
    private func beginDragIfNeeded(of id: UUID) {
        guard drag?.id != id || drag?.isSettling == true else { return }
        let entries = upcomingEntries
        guard let from = entries.firstIndex(where: { $0.id == id }), let frame = rowFrames[id] else { return }
        // Rows the lazy stack has not rendered lie wholly above or below the visible ones; scrolling is off while dragging.
        let firstKnown = entries.firstIndex { rowFrames[$0.id] != nil } ?? from
        let midYs = entries.indices.map { index in
            rowFrames[entries[index].id]?.midY ?? (index < firstKnown ? -.infinity : .infinity)
        }
        let heights = entries.map { rowFrames[$0.id]?.height ?? frame.height }
        drag = QueueDrag(id: id, entry: entries[from], from: from, frame: frame,
                         midYs: midYs, rowHeights: heights, entryIDs: entries.map(\.id))
    }

    /// Drops move the dragged entry to the live target, with the reflow already on screen, so nothing animates again.
    private func commitDrag(of id: UUID) {
        guard let drag, drag.id == id else { return }
        let target = placement?.target ?? drag.from
        guard target != drag.from else {
            guard let animation = reflowAnimation else { self.drag = nil; dragOffset = 0; return }
            self.drag?.isSettling = true
            withAnimation(animation) { dragOffset = 0 } completion: {
                if self.drag?.id == id, self.drag?.isSettling == true { self.drag = nil }
            }
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.drag = nil
            dragOffset = 0
            playback.moveUpcoming(id, toUpcomingOffset: target)
        }
    }

    /// Clears a drag whose gesture was cancelled without ending (sheet dismissed, system interruption).
    /// Runs on the next main-queue turn so a normal drop's `dragEnded` has already committed.
    private func cancelDragIfStale(of id: UUID) {
        DispatchQueue.main.async {
            guard let drag, drag.id == id, !drag.isSettling else { return }
            self.drag = nil
            dragOffset = 0
        }
    }
}

/// Row padding and an inset separator, standing in for grouped List row chrome.
private struct QueueRowChrome: ViewModifier {
    let showsSeparator: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DowntifyStyle.Space.regular)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showsSeparator {
                    Divider().padding(.leading, DowntifyStyle.Space.regular)
                }
            }
    }
}

/// Geometry and identity of the row being dragged, captured at lift.
private struct QueueDrag {
    let id: UUID
    let entry: PlaybackQueueEntry
    let from: Int
    let frame: CGRect
    let midYs: [CGFloat]
    let rowHeights: [CGFloat]
    let entryIDs: [UUID]
    /// Animating back to its own slot after a drop that changed nothing.
    var isSettling = false
}

private struct QueueRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Position of an upcoming queue entry, the action that moves it, and the drag callbacks for its handle.
/// Drag callbacks carry the vertical translation since the lift.
private struct QueueReorder {
    let position: Int
    let count: Int
    let move: (Int) -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat) -> Void
    let dragCancelled: () -> Void
}

private struct QueueEntryRow: View {
    @Environment(\.downtifyPalette) private var palette
    let entry: PlaybackQueueEntry
    let isCurrent: Bool
    @ObservedObject var playback: PlaybackController
    var reorder: QueueReorder?
    /// Non-interactive copy drawn under the finger while this entry is dragged.
    var isLifted = false
    @GestureState private var isHandleDragging = false

    var body: some View {
        HStack(spacing: DowntifyStyle.Space.small) {
            if let reorder { handle(reorder) } else if isLifted { handleIcon }
            Button { playback.select(entry.id) } label: {
                DowntifyMediaRow(title: entry.item.displayTitle, subtitle: entry.item.displayArtist) {
                    PlaybackItemArtwork(item: entry.item, size: 44)
                } accessory: {
                    if isCurrent {
                        Label("Current track", systemImage: "speaker.wave.2.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(entry.item.accessibleMetadata))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint(isCurrent ? String(localized: "Current queue entry") : String(localized: "Play this queue entry"))

            Button(role: .destructive) { playback.remove(entry.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DowntifyStyle.secondaryText)
                    .downtifyControlTarget()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(entry.item.displayTitle) from queue")
        }
        .padding(.vertical, 3)
    }

    private var handleIcon: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(DowntifyStyle.secondaryText)
            .downtifyControlTarget()
    }

    /// Leading drag handle: touch and hold, then drag. VoiceOver gets Move up / Move down instead.
    private func handle(_ reorder: QueueReorder) -> some View {
        handleIcon
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    // Resets on end and on cancel; a cancel never calls onEnded, so the sheet is told separately.
                    .updating($isHandleDragging) { value, state, _ in
                        if case .second(true, _?) = value { state = true }
                    }
                    .onChanged { value in
                        if case .second(true, let drag?) = value { reorder.dragChanged(drag.translation.height) }
                    }
                    .onEnded { value in
                        if case .second(true, let drag?) = value { reorder.dragEnded(drag.translation.height) }
                    }
            )
            .onChange(of: isHandleDragging) { _, dragging in
                if !dragging { reorder.dragCancelled() }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Reorder \(entry.item.displayTitle)"))
            .accessibilityValue(Text("Position \(Int(reorder.position + 1)) of \(Int(reorder.count))"))
            .accessibilityHint(Text("Touch and hold, then drag to move this song in the queue"))
            .accessibilityIdentifier("queue.handle.\(reorder.position)")
            .accessibilityAction(named: Text("Move up")) {
                if reorder.position > 0 { reorder.move(reorder.position - 1) }
            }
            .accessibilityAction(named: Text("Move down")) {
                if reorder.position < reorder.count - 1 { reorder.move(reorder.position + 1) }
            }
    }
}

@MainActor
final class ArtworkLoader: ObservableObject {
    #if DEBUG
    /// Successful image loads; read by the debug state probe only.
    nonisolated(unsafe) static var debugLoadCount = 0
    #endif
    private let connection: ConnectionService
    private let transport: any HTTPDataLoading
    private let cache = NSCache<NSString, UIImage>()
    private var cachedSession: DeviceSession?
    /// Covers saved with downloaded songs; checked before the server so they show offline.
    weak var savedCovers: (any OfflineCoverProviding)?

    init(connection: ConnectionService, transport: any HTTPDataLoading = ConnectionHTTPTransport()) {
        self.connection = connection
        self.transport = transport
        cache.countLimit = 200
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func removeAll() {
        cache.removeAllObjects()
        tints.removeAll()
        cachedSession = nil
    }

    private var tints: [String: Color] = [:]

    /// Cover color already computed for this track, without loading anything.
    func cachedTint(for track: LibraryTrack) -> Color? { tints[track.id] }

    /// Background color taken from the track's cover; nil when the track has no cover or it cannot load.
    func tint(for track: LibraryTrack) async -> Color? {
        if let cached = tints[track.id] { return cached }
        var image = cachedImage(for: track)
        if image == nil { image = await self.image(for: track, size: 150) }
        guard let image, let tint = ArtworkThemeTint.color(from: image) else { return nil }
        if tints.count > 300 { tints.removeAll() }
        tints[track.id] = tint
        return tint
    }

    func image(for track: LibraryTrack, size: Int) async -> UIImage? {
        guard track.hasCover, !track.id.isEmpty else { return nil }
        let saved: () async -> UIImage? = { [weak self] in
            guard let cover = self?.savedCovers?.savedCover(for: track.id) else { return nil }
            let longest = max(cover.size.width, cover.size.height) * cover.scale
            guard longest > CGFloat(size) else { return cover }
            let scale = CGFloat(size) / longest
            let target = CGSize(width: cover.size.width * cover.scale * scale, height: cover.size.height * cover.scale * scale)
            return await cover.byPreparingThumbnail(ofSize: target) ?? cover
        }
        return await image(key: "track:\(track.id):\(size)", saved: saved) { address in
            let url = address.url(for: "/api/v1/tracks").appendingPathComponent(track.id).appendingPathComponent("cover")
            return (url, URLQueryItem(name: "size", value: String(size)))
        }
    }

    /// The largest cover already in memory for this track at any requested size, without a network request.
    func cachedImage(for track: LibraryTrack) -> UIImage? {
        guard track.hasCover, !track.id.isEmpty, cachedSession != nil else { return nil }
        return [600, 150].lazy.compactMap { self.cache.object(forKey: "track:\(track.id):\($0)" as NSString) }.first
    }

    func playlistImage(file: String) async -> UIImage? {
        guard !file.isEmpty else { return nil }
        return await image(key: "playlist:\(file)") { address in
            (address.url(for: "/playlist-cover"), URLQueryItem(name: "file", value: file))
        }
    }

    private func image(key: String, saved: (() async -> UIImage?)? = nil,
                       route: (ServerAddress) -> (URL, URLQueryItem)) async -> UIImage? {
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
            if let image = await saved?() {
                guard !Task.isCancelled, cachedSession == session else { return nil }
                cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.scale * image.size.height * image.scale))
                return image
            }
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
            #if DEBUG
            ArtworkLoader.debugLoadCount += 1
            #endif
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
    @Environment(\.downtifyPalette) private var palette

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
                    .clipShape(RoundedRectangle(cornerRadius: size * (palette.redesign("library") ? 0.04 : 0.08), style: .continuous))
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
            // A cover only a few pixels wide is a stand-in, not artwork; show the placeholder instead.
            if let loaded = loadedImage, loaded.size.width * loaded.scale < 8 { loadedImage = nil }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) {
                image = loadedImage
            }
        }
    }
}

private struct ArtworkPlaceholder: View {
    @Environment(\.downtifyPalette) private var palette
    let size: CGFloat

    var body: some View {
        if palette.redesign("library") {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.16)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .regular))
                    .foregroundStyle(Color(white: 0.62))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(LinearGradient(colors: [palette.accent.opacity(0.25), palette.accent.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.30, weight: .light))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

func playbackFailureMessage(_ failure: PlaybackFailure, isPodcast: Bool = false) -> LocalizedStringKey {
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
            .previewDisplayName("Library error · OLED, Large Type")
        }
    }
}
#endif

// MARK: - Apple Translation integration (iOS 18+)

/// Adds the translation task and availability check on iOS 18 and later. Earlier systems never resolve
/// availability, so the model stays hidden and the existing lyrics experience is unchanged.
private struct LyricsTranslationSupport: ViewModifier {
    let model: LyricsTranslationModel

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(LyricsTranslationHost(model: model))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct LyricsTranslationHost: ViewModifier {
    @ObservedObject var model: LyricsTranslationModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .task(id: model.availabilityRequest) {
                guard model.availabilityRequest != nil else { return }
                await model.resolveAvailability(using: SystemLyricsAvailability())
            }
            .onChange(of: model.requestKey) { _, key in
                guard key != nil, let target = model.target else {
                    configuration = nil  // cancels any in-flight session
                    return
                }
                let next = TranslationSession.Configuration(source: model.sourceLanguage, target: target)
                if configuration == next { configuration?.invalidate() } else { configuration = next }
            }
            .translationTask(configuration) { session in
                guard let key = await model.requestKey else { return }
                await model.run(using: SessionLyricsTranslator(session: session), key: key)
            }
    }
}

@available(iOS 18.0, *)
private struct SystemLyricsAvailability: LyricsLanguageAvailabilityChecking {
    func status(sampleText: String, source: Locale.Language?, target: Locale.Language) async -> LyricsLanguageStatus {
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source {
            status = await availability.status(from: source, to: target)
        } else if let detected = try? await availability.status(for: sampleText, to: target) {
            status = detected
        } else {
            return .unsupported
        }
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

@available(iOS 18.0, *)
private struct SessionLyricsTranslator: LyricsTranslating {
    let session: TranslationSession

    func translate(_ text: String) async throws -> String {
        do { return try await session.translate(text).targetText }
        catch { throw Self.map(error) }
    }

    func translate(batch: [LyricsTranslationItem]) async throws -> [LyricsTranslationItem] {
        let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        do {
            let responses = try await session.translations(from: requests)
            return responses.compactMap { response in
                response.clientIdentifier.map { LyricsTranslationItem(id: $0, text: response.targetText) }
            }
        } catch { throw Self.map(error) }
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        switch error {
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing, TranslationError.unableToIdentifyLanguage:
            return LyricsTranslationFailure.unsupported
        case TranslationError.nothingToTranslate:
            return LyricsTranslationFailure.failed
        default:
            // verify on device (Task 4): the error thrown when the user declines the language download sheet.
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                return LyricsTranslationFailure.declined
            }
            return error
        }
    }
}
