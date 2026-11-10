import SwiftUI

/// Search surface for the synced library and the server catalog. Provider navigation and
/// server-side download submission are injected so this view never treats provider IDs as
/// library IDs and can be wired to the app's existing coordinators.
struct CatalogSearchView: View {
    @ObservedObject var catalog: CatalogPresentationModel
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    var onOpenAlbum: (CatalogAlbum) -> Void = { _ in }
    var onOpenArtist: (CatalogArtist) -> Void = { _ in }
    var onDownloadAlbum: (String) -> Void = { _ in }
    var albumDownloadState: (String) -> ServerDownloadActionState = { _ in .idle }
    var onDownload: (CatalogSong) -> Void = { _ in }
    var downloadState: (CatalogSong) -> ServerDownloadActionState = { _ in .idle }

    @State private var query = ""
    @State private var link = ""
    @Environment(\.downtifyPalette) private var palette

    init(catalog: CatalogPresentationModel, library: LibraryPresentationModel,
         playback: PlaybackController,
         onOpenAlbum: @escaping (CatalogAlbum) -> Void = { _ in },
         onOpenArtist: @escaping (CatalogArtist) -> Void = { _ in },
         onDownloadAlbum: @escaping (String) -> Void = { _ in },
         albumDownloadState: @escaping (String) -> ServerDownloadActionState = { _ in .idle },
         onDownload: @escaping (CatalogSong) -> Void = { _ in },
         downloadState: @escaping (CatalogSong) -> ServerDownloadActionState = { _ in .idle }) {
        self.catalog = catalog
        self.library = library
        self.playback = playback
        self.onOpenAlbum = onOpenAlbum
        self.onOpenArtist = onOpenArtist
        self.onDownloadAlbum = onDownloadAlbum
        self.albumDownloadState = albumDownloadState
        self.onDownload = onDownload
        self.downloadState = downloadState
    }

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var localSongs: [LibraryTrack] { LibraryTrackOrdering.matching(library.tracks, query: normalizedQuery) }
    private var localAlbums: [LibraryBrowseEntry] {
        guard !normalizedQuery.isEmpty else { return [] }
        return library.catalog.albumsByID.values.filter {
            $0.title.localizedStandardContains(normalizedQuery) || $0.artist.localizedStandardContains(normalizedQuery)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var localArtists: [LibraryBrowseEntry] {
        guard !normalizedQuery.isEmpty else { return [] }
        return library.catalog.artistsByID.values.filter { $0.title.localizedStandardContains(normalizedQuery) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("Songs, albums, artists", text: $query)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .accessibilityLabel("Search songs, albums, and artists")

            if !normalizedQuery.isEmpty {
                localResults
                catalogResults
            } else {
                ContentUnavailableView("Search your music", systemImage: "magnifyingglass",
                                       description: Text("Search saved music and available catalog results."))
            }

            if catalog.externalCatalogAvailable {
                linkResolver
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background)
        .task(id: normalizedQuery) {
            guard !normalizedQuery.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            catalog.search(normalizedQuery)
        }
        .onAppear { catalog.start() }
    }

    @ViewBuilder private var localResults: some View {
        if !localSongs.isEmpty {
            sectionHeader("In your library")
            ForEach(localSongs) { track in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.body.weight(.semibold))
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { playback.replaceQueue(localSongs, startingAt: localSongs.firstIndex(of: track) ?? 0) } label: {
                        Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Play \(track.title)")
                }
                .padding(.vertical, 4)
            }
        }
        if !localAlbums.isEmpty {
            sectionHeader("Library albums")
            ForEach(localAlbums) { entry in
                NavigationLink(value: entry.context) {
                    Label("\(entry.title) · \(entry.artist)", systemImage: "square.stack")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
        if !localArtists.isEmpty {
            sectionHeader("Library artists")
            ForEach(localArtists) { entry in
                NavigationLink(value: entry.context) {
                    Label(entry.title, systemImage: "person")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var catalogResults: some View {
        switch catalog.searchSongsState {
        case .loading:
            ProgressView("Searching catalog…")
        case .failed(let message), .unavailable(let message):
            Text(message).foregroundStyle(.secondary)
        case .loaded(let songs), .partial(let songs, _):
            songResults(songs)
        case .empty:
            EmptyView()
        case .idle:
            EmptyView()
        }

        switch catalog.searchAlbumsState {
        case .loaded(let albums), .partial(let albums, _):
            if !albums.isEmpty {
                sectionHeader("Catalog albums")
                ForEach(albums) { album in
                    HStack {
                        Button { onOpenAlbum(album) } label: {
                            Label("\(album.title) · \(album.artist)", systemImage: "square.stack")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain)
                        if canRequestAlbumDownload(album), let url = album.url {
                            serverAlbumDownloadButton(url: url, title: album.title)
                        }
                    }
                }
            }
        case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
        default: EmptyView()
        }

        switch catalog.searchArtistsState {
        case .loaded(let artists), .partial(let artists, _):
            if !artists.isEmpty {
                sectionHeader("Catalog artists")
                ForEach(artists) { artist in
                    Button { onOpenArtist(artist) } label: {
                        Label(artist.name, systemImage: "person")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    @ViewBuilder private func songResults(_ songs: [CatalogSong]) -> some View {
        if !songs.isEmpty {
            sectionHeader("Catalog songs")
            ForEach(songs) { song in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.body.weight(.semibold))
                        Text([song.artist, song.albumName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        if song.source == "library" {
                            guard let track = song.libraryTrack(in: library.tracks) else { return }
                            playback.replaceQueue([.library(track)])
                            return
                        }
                        let item = PlaybackItem.resolving(song, in: library.tracks)
                        playback.replaceQueue([item])
                    } label: { Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Play \(song.title)")
                    .disabled(song.source == "library" && song.libraryTrack(in: library.tracks) == nil)
                    if song.source != "library", catalog.externalCatalogAvailable {
                        serverDownloadButton(for: song)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var linkResolver: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Resolve a link")
            HStack {
                TextField("Paste a music link", text: $link)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Music link to resolve")
                Button("Resolve") { catalog.resolveURL(link.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            switch catalog.urlResolutionState {
            case .loading: ProgressView("Resolving link…")
            case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
            case .loaded(let resolution), .partial(let resolution, _):
                Text(resolution.name).font(.headline)
                Text(resolution.subtitle).font(.subheadline).foregroundStyle(.secondary)
                songResults(resolution.tracks)
                if !resolution.albums.isEmpty {
                    sectionHeader("Albums in this link")
                    ForEach(resolution.albums) { album in
                        HStack {
                            Button { onOpenAlbum(album) } label: {
                                Label("\(album.title) · \(album.artist)", systemImage: "square.stack")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                            if canRequestAlbumDownload(album), let url = album.url {
                                serverAlbumDownloadButton(url: url, title: album.title)
                            }
                        }
                    }
                }
            default: EmptyView()
            }
        }
        .padding(.top, 8)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader).padding(.top, 8)
    }

    @ViewBuilder private func serverDownloadButton(for song: CatalogSong) -> some View {
        let state = downloadState(song)
        Button { onDownload(song) } label: {
            switch state {
            case .submitting: ProgressView().frame(width: 44, height: 44)
            case .queued, .accepted, .partiallyAccepted: Image(systemName: "checkmark.circle.fill").frame(width: 44, height: 44)
            case .failed: Image(systemName: "arrow.clockwise.circle").frame(width: 44, height: 44)
            case .idle, .outcomeUnknown: Image(systemName: "arrow.down.circle").frame(width: 44, height: 44)
            }
        }
        .disabled(disablesDownloadAction(state))
        .accessibilityLabel(downloadAccessibilityLabel(state, title: song.title))
    }

    private func downloadAccessibilityLabel(_ state: ServerDownloadActionState, title: String) -> String {
        switch state {
        case .submitting: "Requesting server download for \(title)"
        case .queued, .accepted, .partiallyAccepted: "Server download requested for \(title)"
        case .outcomeUnknown: "Server download status unknown for \(title)"
        case .failed: "Retry server download for \(title)"
        case .idle: "Request server download for \(title)"
        }
    }

    private func disablesDownloadAction(_ state: ServerDownloadActionState) -> Bool {
        switch state {
        case .submitting, .queued, .accepted, .partiallyAccepted, .outcomeUnknown: return true
        case .idle, .failed: return false
        }
    }

    private func canRequestAlbumDownload(_ album: CatalogAlbum) -> Bool {
        guard catalog.externalCatalogAvailable, let url = album.url else { return false }
        return ServerDownloadQueue.isYouTubeMusicAlbumURL(url)
    }

    @ViewBuilder private func serverAlbumDownloadButton(url: String, title: String) -> some View {
        let state = albumDownloadState(url)
        Button { onDownloadAlbum(url) } label: {
            switch state {
            case .submitting: ProgressView().frame(width: 44, height: 44)
            case .queued, .accepted, .partiallyAccepted: Image(systemName: "checkmark.circle.fill").frame(width: 44, height: 44)
            case .failed: Image(systemName: "arrow.clockwise.circle").frame(width: 44, height: 44)
            case .idle, .outcomeUnknown: Image(systemName: "arrow.down.circle").frame(width: 44, height: 44)
            }
        }
        .disabled(disablesDownloadAction(state))
        .accessibilityLabel(downloadAccessibilityLabel(state, title: title))
    }
}
