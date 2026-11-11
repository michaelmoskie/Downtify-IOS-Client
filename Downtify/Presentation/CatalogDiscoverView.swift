import SwiftUI

/// Catalog discovery surfaces. Provider IDs stay inside the catalog models; the
/// coordinator receives typed songs for playback and download actions.
struct CatalogDiscoverView: View {
    @ObservedObject var catalog: CatalogPresentationModel
    var libraryTracks: [LibraryTrack] = []
    var libraryArtists: [CatalogLibraryArtist] = []
    var libraryAlbums: [CatalogLibraryAlbum] = []
    var playlistNames: [String] = []
    var playlistIDs: [String] = []
    var shownArtists: [String] = []
    var onPlay: (CatalogSong) -> Void
    var onDownload: (CatalogSong) -> Void
    var onDownloadAlbum: (String, [CatalogSong]?) -> Void = { _, _ in }
    var downloadState: (CatalogSong) -> ServerDownloadActionState = { _ in .idle }
    var albumDownloadState: (String) -> ServerDownloadActionState = { _ in .idle }
    var onOpenURL: (URL) -> Void = { _ in }

    @Environment(\.downtifyPalette) private var palette
    @AppStorage("catalog.discover.section") private var selectedSection = "Finder"
    @State private var query = ""
    @State private var similarArtist = ""
    @State private var similarTrack = ""
    @State private var isSearching = false

    private enum Section: String, CaseIterable, Identifiable {
        case finder = "Finder", discover = "For You", charts = "Charts", similar = "Similar"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Explore", selection: $selectedSection) {
                ForEach(Section.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Discovery section")

            switch Section(rawValue: selectedSection) ?? .finder {
            case .finder: finderContent
            case .discover: discoverContent
            case .charts: chartsContent
            case .similar: similarContent
            }
        }
        .onAppear(perform: loadInitial)
        .onChange(of: selectedSection) { _, rawValue in
            let value = Section(rawValue: rawValue) ?? .finder
            if value == .charts, catalog.chartsState == .idle { catalog.loadCharts() }
            if value == .discover { loadDiscover() }
        }
        .onChange(of: catalog.policyGeneration) { _, _ in loadInitial() }
        .onChange(of: catalog.policyState) { _, value in
            if value == .ready { loadInitial() }
        }
    }

    private var finderContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Songs, artists, albums", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(searchFinder)
                    .accessibilityLabel("Search Finder")
                if !query.isEmpty {
                    Button { query = ""; isSearching = false; catalog.clearFinderSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.accessibilityLabel("Clear search")
                }
                Button(action: searchFinder) {
                    Image(systemName: "arrow.right.circle.fill").font(.title2)
                }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Search")
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))

            if isSearching || !query.isEmpty {
                switch catalog.finderSearchState {
                case .idle: Text("Search Deezer's catalog for songs, albums, and artists.").foregroundStyle(.secondary)
                case .loading: ProgressView("Searching Finder…").frame(maxWidth: .infinity)
                case .empty: emptyMessage("No Finder results", symbol: "magnifyingglass", detail: "Try another artist, album, or song.")
                case .unavailable(let message): statusMessage(message, symbol: "wifi.slash")
                case .failed(let message): statusMessage(message, symbol: "exclamationmark.triangle", retry: searchFinder)
                case .partial(let results, let message): finderResults(results); Text(message).font(.caption).foregroundStyle(.secondary)
                case .loaded(let results): finderResults(results)
                }
            } else {
                heroCard(title: "Find something new", subtitle: "Explore songs, albums, and artists from the catalog.", symbol: "sparkle.magnifyingglass")
                if catalog.isLibraryOnly == true {
                    Text("Finder uses the server's local catalog in library-only mode. Provider artist and album details may be unavailable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func finderResults(_ results: CatalogSearchResults) -> some View {
        if !results.tracks.isEmpty {
            sectionHeading("Songs", count: results.tracks.count)
            ForEach(results.tracks) { songRow($0) }
        }
        if !results.artists.isEmpty {
            sectionHeading("Artists", count: results.artists.count)
            ForEach(results.artists) { artist in
                Button { selectFinderArtist(artist) } label: {
                    entityRow(title: artist.name, subtitle: "Artist", artworkURL: artist.coverURL, symbol: "person.crop.circle")
                }.buttonStyle(.plain)
            }
        }
        if !results.albums.isEmpty {
            sectionHeading("Albums", count: results.albums.count)
            ForEach(results.albums) { album in
                Button { selectFinderAlbum(album) } label: {
                    entityRow(title: album.title, subtitle: album.artist, artworkURL: album.coverURL, symbol: "square.stack")
                }.buttonStyle(.plain)
            }
        }
        finderDetails
    }

    @ViewBuilder private var finderDetails: some View {
        switch catalog.finderArtistState {
        case .loaded(let artist), .partial(let artist, _):
            sectionHeading(artist.artist.name, count: artist.topSongs.count)
            if !artist.bio.isEmpty { Text(artist.bio).font(.subheadline).foregroundStyle(.secondary).lineLimit(5) }
            if !artist.related.isEmpty {
                Text("Related artists").font(.headline)
                ForEach(artist.related) { related in
                    Button { selectFinderArtist(related) } label: {
                        entityRow(title: related.name, subtitle: "Related artist", artworkURL: related.coverURL, symbol: "person.2")
                    }.buttonStyle(.plain)
                }
            }
                artistSongsSection(artist)
                artistAlbumsSection
            if let url = artist.artist.url { openProviderButton(url, label: "Open artist on Deezer") }
        case .loading: ProgressView("Loading artist…")
        case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "person.crop.circle")
        default: EmptyView()
        }
        switch catalog.finderAlbumState {
        case .loaded(let album), .partial(let album, _):
            sectionHeading(album.album.title, count: album.tracks.count)
            if let url = album.album.url { openProviderButton(url, label: "Open album on Deezer") }
            ForEach(album.tracks) { songRow($0) }
        case .loading: ProgressView("Loading album…")
        case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "square.stack")
        default: EmptyView()
        }
    }

    @ViewBuilder private func artistSongsSection(_ artist: CatalogFinderArtist) -> some View {
        switch catalog.finderArtistSongsState {
        case .loading: ProgressView("Loading artist songs…")
        case .loaded(let songs), .partial(let songs, _):
            if !songs.isEmpty {
                sectionHeading("Songs", count: songs.count)
                ForEach(songs) { songRow($0) }
            } else if !artist.topSongs.isEmpty {
                sectionHeading("Top songs", count: artist.topSongs.count)
                ForEach(artist.topSongs) { songRow($0) }
            }
        case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "music.note")
        case .empty, .idle:
            if !artist.topSongs.isEmpty {
                sectionHeading("Top songs", count: artist.topSongs.count)
                ForEach(artist.topSongs) { songRow($0) }
            }
        }
    }

    @ViewBuilder private var artistAlbumsSection: some View {
        switch catalog.finderArtistAlbumsState {
        case .loading: ProgressView("Loading artist albums…")
        case .loaded(let albums), .partial(let albums, _):
            if !albums.isEmpty {
                sectionHeading("Albums", count: albums.count)
                ForEach(albums) { album in
                        albumEntityRow(album) { catalog.loadFinderAlbum(id: album.deezerAlbumID ?? album.albumID) }
                }
            }
        case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "square.stack")
        case .idle, .empty: EmptyView()
        }
    }

    private var chartsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("What's moving now").font(.title3.bold()); Spacer(); Button { catalog.loadCharts() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh charts") }
            switch catalog.chartsState {
            case .idle, .loading: ProgressView("Loading charts…").frame(maxWidth: .infinity)
            case .empty: emptyMessage("Charts are empty", symbol: "chart.bar", detail: "There are no chart results right now.")
            case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "chart.bar", retry: { catalog.loadCharts() })
            case .loaded(let charts), .partial(let charts, _):
                if !charts.tracks.isEmpty { sectionHeading("Top tracks", count: charts.tracks.count); ForEach(charts.tracks) { songRow($0) } }
                if !charts.albums.isEmpty {
                    sectionHeading("Albums", count: charts.albums.count)
                    ForEach(charts.albums) { album in
                        albumEntityRow(album) { if let url = album.url { openProviderURL(url) } }
                    }
                }
                if !charts.artists.isEmpty {
                    sectionHeading("Artists", count: charts.artists.count)
                    ForEach(charts.artists) { artist in
                        Button { if let url = artist.url { openProviderURL(url) } } label: {
                            entityRow(title: artist.name, subtitle: "Artist", artworkURL: artist.coverURL, symbol: "person.crop.circle")
                        }.buttonStyle(.plain)
                    }
                }
                if !charts.playlists.isEmpty { sectionHeading("Playlists", count: charts.playlists.count); ForEach(charts.playlists) { playlist in
                    Button { if let url = playlist.url { openProviderURL(url) } } label: { entityRow(title: playlist.name, subtitle: playlist.owner ?? "Playlist", artworkURL: playlist.coverURL, symbol: "list.bullet.rectangle") }.buttonStyle(.plain)
                } }
            }
        }
    }

    private var discoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Picked for your library").font(.title3.bold()); Text("Suggestions use this account's library context.").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Button { loadDiscover() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh recommendations") }
            switch catalog.discoverArtistsState {
            case .idle, .loading: ProgressView("Finding artists…").frame(maxWidth: .infinity)
            case .empty: emptyMessage("No suggestions yet", symbol: "sparkles", detail: "Add or like music, then refresh your recommendations.")
            case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "sparkles", retry: loadDiscover)
            case .loaded(let result), .partial(let result, _):
                if !result.seeds.isEmpty {
                    let seeds = result.seeds.prefix(4).joined(separator: " · ")
                    Text("Based on \(seeds)").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(result.artists.filter { !blockedArtistNames.contains($0.name.lowercased()) }) { artist in
                    HStack {
                            Button { query = artist.name; selectedSection = Section.finder.rawValue; searchFinder() } label: {
                            entityRow(title: artist.name, subtitle: "Explore songs", artworkURL: artist.coverURL, symbol: "person.crop.circle")
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Find songs", systemImage: "magnifyingglass") { query = artist.name; selectedSection = Section.finder.rawValue; searchFinder() }
                            Button("Hide recommendation", systemImage: "eye.slash", role: .destructive) { catalog.blockArtist(artist.name) }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("More options for \(artist.name)")
                    }
                }
                if case .partial(_, let message) = catalog.discoverArtistsState { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            collectionSection("Deezer collections", state: catalog.deezerCollectionsState)
            collectionSection("Spotify collections", state: catalog.spotifyCollectionsState)
            blockedArtistsSection
            if catalog.isLibraryOnly == true { Text("External collections and actions are disabled in library-only mode.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var blockedArtistsSection: some View {
        switch catalog.blockedArtistsState {
        case .loaded(let artists), .partial(let artists, _):
            if !artists.isEmpty {
                sectionHeading("Hidden artists", count: artists.count)
                ForEach(artists) { artist in
                    HStack {
                        Text(artist.name).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Unhide") { catalog.unblockArtist(artist.name) }
                            .buttonStyle(.bordered)
                            .disabled(catalog.mutationState == .loading)
                    }
                }
            }
        case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "eye.slash")
        default: EmptyView()
        }
        if case .failed(let message) = catalog.mutationState {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func collectionSection(_ title: String, state: CatalogLoadState<CatalogCollectionsResults>) -> some View {
        switch state {
        case .loaded(let value), .partial(let value, _):
            let albums = value.albums + value.moreAlbums
            if !albums.isEmpty || !value.playlists.isEmpty {
                sectionHeading(title, count: albums.count + value.playlists.count)
                ForEach(albums) { album in albumEntityRow(album) { if let url = album.url { openProviderURL(url) } } }
                ForEach(value.playlists) { playlist in
                    Button { if let url = playlist.url { openProviderURL(url) } } label: { entityRow(title: playlist.name, subtitle: playlist.owner ?? title, artworkURL: playlist.coverURL, symbol: "list.bullet.rectangle") }.buttonStyle(.plain)
                }
            }
        case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "rectangle.stack")
        default: EmptyView()
        }
    }

    private var similarContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroCard(title: "Keep the music going", subtitle: "Start with an artist or track and find a radio-style list of similar songs.", symbol: "waveform.path")
            HStack {
                TextField("Artist", text: $similarArtist).textFieldStyle(.roundedBorder).accessibilityLabel("Similar artist")
                TextField("Track", text: $similarTrack).textFieldStyle(.roundedBorder).accessibilityLabel("Similar track")
            }
            Button { loadSimilar() } label: { Label("Find similar tracks", systemImage: "waveform") }.buttonStyle(.borderedProminent)
                .disabled(similarArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && similarTrack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            switch catalog.similarState {
            case .idle: EmptyView()
            case .loading: ProgressView("Finding similar tracks…")
            case .empty: emptyMessage("No similar tracks found", symbol: "waveform", detail: "Try a different artist or track.")
            case .failed(let message), .unavailable(let message): statusMessage(message, symbol: "waveform", retry: loadSimilar)
            case .loaded(let result), .partial(let result, _):
                sectionHeading("Similar to \([result.artist, result.track].filter { !$0.isEmpty }.joined(separator: " — "))", count: result.tracks.count)
                ForEach(result.tracks) { song in songRow(song, similarAction: true) }
            }
            if catalog.isLibraryOnly == true { Text("Similar results use the server's local catalog in library-only mode.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func songRow(_ song: CatalogSong, similarAction: Bool = false) -> some View {
        HStack(spacing: 10) {
            Button { onPlay(song) } label: {
                DowntifyMediaRow(title: song.title, subtitle: song.artists.joined(separator: ", ").isEmpty ? song.artist : song.artists.joined(separator: ", "), detail: song.albumName.isEmpty ? nil : song.albumName) {
                    artwork(song.coverURL ?? song.previewURL, fallback: "music.note")
                } accessory: { Image(systemName: "play.fill").foregroundStyle(DowntifyStyle.accent).frame(width: 44, height: 44) }
            }.buttonStyle(.plain).accessibilityLabel("Play \(song.title) by \(song.artist)")
                .disabled(song.source == "library" && song.libraryTrack(in: libraryTracks) == nil)
            if song.source != "library", catalog.isLibraryOnly != true {
                serverDownloadButton(for: song)
            }
            if similarAction { Button { similarArtist = song.artist; similarTrack = song.title; loadSimilar() } label: { Image(systemName: "waveform").frame(width: 40, height: 44) }.buttonStyle(.plain).accessibilityLabel("Find tracks similar to \(song.title)") }
        }
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
        .buttonStyle(.plain)
        .disabled(disablesDownloadAction(state))
        .accessibilityLabel(downloadAccessibilityLabel(state, title: song.title))
    }

    private func albumEntityRow(_ album: CatalogAlbum, open: @escaping () -> Void) -> some View {
        HStack {
            Button(action: open) {
                entityRow(title: album.title, subtitle: album.artist, artworkURL: album.coverURL, symbol: "square.stack")
            }.buttonStyle(.plain)
            if canRequestAlbumDownload(album), let url = album.url {
                serverAlbumDownloadButton(url: url, title: album.title)
            }
        }
    }

    private func canRequestAlbumDownload(_ album: CatalogAlbum) -> Bool {
        guard catalog.externalCatalogAvailable, let url = album.url else { return false }
        return ServerDownloadQueue.isYouTubeMusicAlbumURL(url)
    }

    @ViewBuilder private func serverAlbumDownloadButton(url: String, title: String) -> some View {
        let state = albumDownloadState(url)
        Button { onDownloadAlbum(url, resolvedAlbumTracks(for: url)) } label: {
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

    private func resolvedAlbumTracks(for url: String) -> [CatalogSong]? {
        switch catalog.finderAlbumState {
        case .loaded(let details), .partial(let details, _):
            return details.album.url == url ? details.tracks : nil
        default: return nil
        }
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

    private func entityRow(title: String, subtitle: String, artworkURL: String?, symbol: String) -> some View {
        DowntifyMediaRow(title: title, subtitle: subtitle) { artwork(artworkURL, fallback: symbol) } accessory: { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary).frame(width: 24, height: 44) }
    }

    @ViewBuilder private func artwork(_ value: String?, fallback: String) -> some View {
        if let value, let url = URL(string: value), url.scheme == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { artworkPlaceholder(fallback) }
            }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        } else { artworkPlaceholder(fallback) }
    }

    private func artworkPlaceholder(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 48, height: 48).background(palette.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Text("\(count)").font(.caption).foregroundStyle(.secondary) }.padding(.top, 6)
    }

    private func heroCard(title: String, subtitle: String, symbol: String) -> some View {
        DowntifyCard {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(DowntifyStyle.accent).frame(width: 44, height: 44).background(DowntifyStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    private func emptyMessage(_ title: LocalizedStringKey, symbol: String, detail: String) -> some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) }.frame(maxWidth: .infinity)
    }

    private func statusMessage(_ message: String, symbol: String, retry: (() -> Void)? = nil) -> some View {
        DowntifyUnavailableView(title: "Catalog unavailable", symbol: symbol, message: Text(message), retry: retry)
    }

    private func openProviderButton(_ value: String, label: String) -> some View {
        Button(label, systemImage: "arrow.up.right.square") { openProviderURL(value) }.buttonStyle(.bordered)
    }

    private func openProviderURL(_ value: String) {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return }
        onOpenURL(url)
    }

    private func searchFinder() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        catalog.searchFinder(query)
    }

    private func selectFinderArtist(_ artist: CatalogArtist) {
        if catalog.isLibraryOnly == true {
            query = artist.name
            isSearching = true
            catalog.clearFinderSearch()
            catalog.searchFinder(artist.name)
        } else {
            catalog.loadFinderArtist(id: artist.deezerID ?? artist.artistID, name: artist.name)
        }
    }

    private func selectFinderAlbum(_ album: CatalogAlbum) {
        if catalog.isLibraryOnly == true {
            query = album.title
            isSearching = true
            catalog.clearFinderSearch()
            catalog.searchFinder(album.title)
        } else {
            catalog.loadFinderAlbum(id: album.deezerAlbumID ?? album.albumID)
        }
    }

    private func loadInitial() {
        if catalog.chartsState == .idle { catalog.loadCharts() }
        if catalog.isLibraryOnly == true || catalog.providerFinderDetailsAvailable { loadDiscover() }
    }

    private func loadDiscover() {
        catalog.loadDiscover(library: libraryArtists, albums: libraryAlbums,
                             playlistNames: playlistNames, playlistIDs: playlistIDs, shown: shownArtists)
        catalog.loadBlockedArtists()
    }

    private var blockedArtistNames: Set<String> {
        switch catalog.blockedArtistsState {
        case .loaded(let artists), .partial(let artists, _): Set(artists.map { $0.name.lowercased() })
        default: []
        }
    }

    private func loadSimilar() {
        catalog.loadSimilar(artist: similarArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                            track: similarTrack.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
