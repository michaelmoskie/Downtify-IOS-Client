import SwiftUI

/// Artist page opened from Now Playing: the library's songs and albums plus the provider catalog.
struct NowPlayingArtistPage: View {
    let target: NowPlayingArtistTarget
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @EnvironmentObject private var catalog: CatalogPresentationModel
    @Environment(\.downtifyPalette) private var palette
    @StateObject private var model = NowPlayingDetailModel()
    @State private var retryCount = 0
    @State private var bioExpanded = false

    private struct LoadKey: Equatable {
        let target: NowPlayingArtistTarget
        let session: DeviceSession?
        let available: Bool
        let retry: Int
    }

    private var libraryTracks: [LibraryTrack] {
        guard let id = target.libraryArtistID else { return [] }
        return library.catalog.tracks(in: .artist(id), likedIDs: [], playlist: nil)
    }

    private var libraryAlbums: [LibraryBrowseEntry] {
        target.libraryArtistID.map { library.catalog.albums(for: $0) } ?? []
    }

    private var catalogValue: NowPlayingArtistCatalog? {
        switch model.artistState {
        case .loaded(let value), .partial(let value, _): value
        default: nil
        }
    }

    var body: some View {
        let tracks = libraryTracks
        let albums = libraryAlbums
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                header
                if !tracks.isEmpty || !albums.isEmpty {
                    librarySection(tracks: tracks, albums: albums)
                }
                catalogSection(libraryAlbums: albums)
                if tracks.isEmpty && albums.isEmpty && isCatalogSettledWithoutContent {
                    ContentUnavailableView("Nothing to show for this artist", systemImage: "music.mic")
                }
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .downtifyScrollEndClearance()
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("nowPlaying.artistPage")
        .task(id: LoadKey(target: target, session: catalog.session,
                          available: catalog.providerFinderDetailsAvailable, retry: retryCount)) {
            await model.loadArtist(target, session: catalog.session,
                                   providerDetailsAvailable: catalog.providerFinderDetailsAvailable)
        }
    }

    private var isCatalogSettledWithoutContent: Bool {
        switch model.artistState {
        case .empty, .unavailable, .failed: true
        default: false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DowntifyStyle.Space.small) {
            HStack(spacing: DowntifyStyle.Space.regular) {
                RemoteArtwork(url: catalogValue?.artist.coverURL, fallback: libraryTracks.first(where: \.hasCover), size: 96,
                              circular: true)
                Text(target.name)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bio = catalogValue?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(DowntifyStyle.secondaryText)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if bioExpanded {
                        Button("Show less") { bioExpanded = false }
                    } else {
                        Button("Show more") { bioExpanded = true }
                    }
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func librarySection(tracks: [LibraryTrack], albums: [LibraryBrowseEntry]) -> some View {
        DetailSectionHeader(title: "In your library")
        if !tracks.isEmpty {
            PlayShuffleButtons(playback: playback, items: tracks.map(PlaybackItem.library))
        }
        if !albums.isEmpty {
            DetailSectionHeader(title: "Albums", level: .subsection)
            ForEach(albums) { entry in
                NavigationLink(value: NowPlayingRoute.album(NowPlayingAlbumTarget(
                    title: entry.title, artist: entry.artist, libraryAlbumID: entry.id,
                    providerArtistID: target.providerArtistID))) {
                    DowntifyMediaRow(title: entry.title, subtitle: String(localized: "\(entry.count) songs")) {
                        TrackArtwork(track: entry.artwork, size: 56)
                    } accessory: {
                        Image(systemName: "chevron.right").foregroundStyle(DowntifyStyle.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        if !tracks.isEmpty {
            DetailSectionHeader(title: "Songs", level: .subsection)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { playback.replaceQueue(tracks, startingAt: index) } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(track.accessibleMetadata))
                .accessibilityHint("Plays this song")
            }
        }
    }

    @ViewBuilder
    private func catalogSection(libraryAlbums: [LibraryBrowseEntry]) -> some View {
        switch model.artistState {
        case .idle, .loading:
            ProgressView("Loading artist…").frame(maxWidth: .infinity)
        case .loaded(let value), .partial(let value, _):
            if !value.songs.isEmpty {
                DetailSectionHeader(title: "Popular")
                CatalogSongRows(songs: value.songs, library: library, playback: playback, serverDownloads: serverDownloads)
            }
            let albums = ArtistAlbumMerge.catalogOnly(providerAlbums: value.albums, libraryAlbums: libraryAlbums)
            if !albums.isEmpty {
                DetailSectionHeader(title: "More albums")
                ForEach(albums) { album in
                    NavigationLink(value: NowPlayingRoute.album(NowPlayingAlbumTarget(
                        title: album.title, artist: album.artist.isEmpty ? target.name : album.artist,
                        providerAlbumID: CatalogNameMatch.providerAlbumID(album),
                        providerArtistID: CatalogNameMatch.providerArtistID(value.artist)))) {
                        DowntifyMediaRow(title: album.title, subtitle: albumSubtitle(album)) {
                            RemoteArtwork(url: album.coverURL, fallback: nil, size: 56)
                        } accessory: {
                            Image(systemName: "chevron.right").foregroundStyle(DowntifyStyle.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if case .partial(_, let message) = model.artistState {
                CatalogNote(message: message)
            }
        case .empty:
            CatalogNote(message: "No catalog match found for this artist.")
        case .unavailable(let message):
            CatalogNote(message: message)
        case .failed(let message):
            CatalogNote(message: message) { retryCount += 1 }
        }
    }

    private func albumSubtitle(_ album: CatalogAlbum) -> String {
        [album.releaseType, album.year ?? album.releaseDate.map { String($0.prefix(4)) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Album page opened from Now Playing: the provider's full tracklist merged with the library's copy.
struct NowPlayingAlbumPage: View {
    let target: NowPlayingAlbumTarget
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @EnvironmentObject private var catalog: CatalogPresentationModel
    @Environment(\.downtifyPalette) private var palette
    @StateObject private var model = NowPlayingDetailModel()
    @State private var retryCount = 0

    private struct LoadKey: Equatable {
        let target: NowPlayingAlbumTarget
        let session: DeviceSession?
        let available: Bool
        let retry: Int
    }

    private var libraryTracks: [LibraryTrack] {
        guard let id = target.libraryAlbumID else { return [] }
        return library.catalog.tracks(in: .album(id), likedIDs: [], playlist: nil)
    }

    private var catalogValue: NowPlayingAlbumCatalog? {
        if case .loaded(let value) = model.albumState { return value }
        return nil
    }

    var body: some View {
        let rows = AlbumTrackMerge.rows(catalogTracks: catalogValue?.tracks ?? [], libraryTracks: libraryTracks)
        let items = AlbumTrackMerge.playbackItems(rows, includeCatalog: catalog.externalCatalogAvailable)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                header(rows: rows)
                if !items.isEmpty {
                    PlayShuffleButtons(playback: playback, items: items)
                }
                let missing = rows.compactMap { row -> CatalogSong? in
                    guard case .catalogOnly(let song) = row, canRequest(song) else { return nil }
                    return song
                }
                if !missing.isEmpty {
                    Button(String(localized: "Add Missing Songs to Library"), systemImage: "plus.circle") {
                        Task { await serverDownloads.requestBatch(songs: missing) }
                    }
                    .buttonStyle(.bordered)
                }
                catalogStatus(hasRows: !rows.isEmpty)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    AlbumRowView(row: row, position: index + 1, isPlayable: playable(row),
                                 serverDownloads: serverDownloads, canRequest: canRequest) {
                        play(rows: rows, from: row)
                    }
                    Divider()
                }
                if rows.contains(where: { if case .catalogOnly = $0 { true } else { false } }) {
                    Text("Songs appear in your Library after the server adds them and the library syncs.")
                        .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
                }
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .downtifyScrollEndClearance()
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("nowPlaying.albumPage")
        .task(id: LoadKey(target: target, session: catalog.session,
                          available: catalog.providerFinderDetailsAvailable, retry: retryCount)) {
            await model.loadAlbum(target, session: catalog.session,
                                  providerDetailsAvailable: catalog.providerFinderDetailsAvailable)
        }
    }

    private func header(rows: [AlbumPageRow]) -> some View {
        VStack(alignment: .center, spacing: DowntifyStyle.Space.small) {
            RemoteArtwork(url: catalogValue?.album.coverURL, fallback: libraryTracks.first(where: \.hasCover), size: 180)
            Text(target.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            if let artist = NowPlayingNavigationResolver.artistTarget(forAlbum: target, catalog: library.catalog) {
                NavigationLink(value: NowPlayingRoute.artist(artist)) {
                    Text(artist.name).font(.title3)
                }
                .accessibilityHint("Opens the artist page")
            }
            if let detail = albumDetail(rows: rows) {
                Text(detail).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func albumDetail(rows: [AlbumPageRow]) -> String? {
        let owned = rows.filter { $0.libraryTrack != nil }.count
        guard catalogValue != nil, !rows.isEmpty else { return nil }
        let year = catalogValue?.album.year ?? catalogValue?.album.releaseDate.map { String($0.prefix(4)) }
        let count = String(localized: "\(Int(owned)) of \(Int(rows.count)) songs in your library")
        return [year, count].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func catalogStatus(hasRows: Bool) -> some View {
        switch model.albumState {
        case .idle, .loading:
            ProgressView("Loading album…").frame(maxWidth: .infinity)
        case .loaded, .partial:
            EmptyView()
        case .empty:
            if hasRows {
                CatalogNote(message: "Showing the songs in your library. The full album was not found in the catalog.")
            } else {
                CatalogNote(message: "Album details are unavailable.")
            }
        case .unavailable(let message):
            CatalogNote(message: message)
        case .failed(let message):
            CatalogNote(message: message) { retryCount += 1 }
        }
    }

    private func playable(_ row: AlbumPageRow) -> Bool {
        if case .catalogOnly = row { return catalog.externalCatalogAvailable }
        return true
    }

    private func canRequest(_ song: CatalogSong) -> Bool {
        guard catalog.externalCatalogAvailable, song.source != "library" else { return false }
        switch serverDownloads.actionState(for: song) {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func play(rows: [AlbumPageRow], from row: AlbumPageRow) {
        let playableRows = rows.filter(playable)
        let items = AlbumTrackMerge.playbackItems(playableRows, includeCatalog: catalog.externalCatalogAvailable)
        guard let index = playableRows.firstIndex(of: row) else { return }
        playback.setShuffle(false)
        playback.replaceQueue(items, startingAt: index)
    }
}

// MARK: - Shared pieces

private struct DetailSectionHeader: View {
    enum Level { case section, subsection }
    let title: LocalizedStringKey
    var level: Level = .section

    var body: some View {
        Text(title)
            .font(level == .section ? .title2.bold() : .headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, level == .section ? DowntifyStyle.Space.small : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CatalogNote: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DowntifyStyle.Space.small) {
            Label(LocalizedStringKey(message), systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(DowntifyStyle.secondaryText)
            if let retry {
                Button("Retry", action: retry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlayShuffleButtons: View {
    let playback: PlaybackController
    let items: [PlaybackItem]

    var body: some View {
        HStack {
            Button("Play", systemImage: "play.fill") {
                playback.setShuffle(false)
                playback.replaceQueue(items)
            }
            .buttonStyle(.borderedProminent)
            Button {
                playback.replaceQueue(items, startingAt: Int.random(in: items.indices))
                playback.setShuffle(true)
            } label: {
                Image(systemName: "shuffle").downtifyControlTarget()
            }
            .accessibilityLabel("Shuffle songs")
        }
    }
}

/// Provider songs, played from the library copy when the library has exactly one match.
private struct CatalogSongRows: View {
    let songs: [CatalogSong]
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @EnvironmentObject private var catalog: CatalogPresentationModel

    var body: some View {
        let tracks = library.tracks
        let owned = songs.map { NowPlayingNavigationResolver.libraryTrack(matching: $0, in: tracks) }
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            HStack(spacing: DowntifyStyle.Space.small) {
                Button { play(from: index, owned: owned) } label: {
                    DowntifyMediaRow(title: song.title, subtitle: song.albumName) {
                        RemoteArtwork(url: song.coverURL, fallback: owned[index], size: 44)
                    } accessory: { EmptyView() }
                }
                .buttonStyle(.plain)
                .disabled(owned[index] == nil && !catalog.externalCatalogAvailable)
                .accessibilityHint("Plays this song")
                if owned[index] != nil {
                    InLibraryBadge()
                } else {
                    LibraryRequestButton(song: song, serverDownloads: serverDownloads,
                                         enabled: catalog.externalCatalogAvailable && song.source != "library")
                }
            }
        }
    }

    private func play(from index: Int, owned: [LibraryTrack?]) {
        var items: [PlaybackItem] = []
        var start = 0
        for (position, song) in songs.enumerated() {
            if position == index { start = items.count }
            if let track = owned[position] { items.append(.library(track)) }
            else if catalog.externalCatalogAvailable { items.append(.catalog(song)) }
        }
        guard !items.isEmpty else { return }
        playback.setShuffle(false)
        playback.replaceQueue(items, startingAt: start)
    }
}

private struct AlbumRowView: View {
    let row: AlbumPageRow
    let position: Int
    let isPlayable: Bool
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    let canRequest: (CatalogSong) -> Bool
    let play: () -> Void

    private var title: String {
        row.libraryTrack?.displayTitle ?? row.catalogSong?.title ?? String(localized: "Unknown title")
    }

    private var number: Int {
        if let number = row.catalogSong?.trackNumber, number > 0 { return number }
        if let number = row.libraryTrack?.trackNumber, number > 0 { return number }
        return position
    }

    private var duration: Double? {
        row.libraryTrack.map(\.duration).flatMap { $0 > 0 ? $0 : nil } ?? row.catalogSong?.duration
    }

    var body: some View {
        HStack(spacing: DowntifyStyle.Space.small) {
            Button(action: play) {
                DowntifyMediaRow(title: title, subtitle: subtitle) {
                    Text(verbatim: "\(number)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(DowntifyStyle.secondaryText)
                        .frame(minWidth: 28)
                } accessory: {
                    if let duration, duration.isFinite, duration > 0 {
                        Text(Duration.seconds(Int(duration.rounded())).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DowntifyStyle.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)
            .accessibilityLabel(Text(verbatim: "\(number). \(title)"))
            .accessibilityHint(isPlayable ? "Plays this song" : "")
            switch row {
            case .owned, .libraryOnly:
                InLibraryBadge()
            case .catalogOnly(let song):
                LibraryRequestButton(song: song, serverDownloads: serverDownloads, enabled: canRequest(song))
            }
        }
    }

    private var subtitle: String {
        switch row {
        case .owned(let track, _), .libraryOnly(let track): track.displayArtist
        case .catalogOnly(let song): song.artist
        }
    }
}

private struct InLibraryBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(DowntifyStyle.accent)
            .downtifyControlTarget()
            .accessibilityLabel("In Library")
    }
}

private struct LibraryRequestButton: View {
    let song: CatalogSong
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    let enabled: Bool

    var body: some View {
        let state = serverDownloads.actionState(for: song)
        let presentation = MediaActionPresentation.library(state, itemTitle: song.title)
        Button {
            Task { await serverDownloads.request(song: song) }
        } label: {
            Image(systemName: presentation.systemImage ?? "hourglass").downtifyControlTarget()
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || !presentation.isEnabled)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// Provider artwork over https, falling back to the library cover and then a placeholder.
private struct RemoteArtwork: View {
    let url: String?
    let fallback: LibraryTrack?
    let size: CGFloat
    var circular = false

    var body: some View {
        Group {
            if let url = url.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https" {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    TrackArtwork(track: fallback, size: size)
                }
                .frame(width: size, height: size)
            } else {
                TrackArtwork(track: fallback, size: size)
            }
        }
        .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)))
        .accessibilityHidden(true)
    }
}
