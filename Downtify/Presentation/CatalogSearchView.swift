import SwiftUI

/// Search surface for the synced library and the server catalog.
struct CatalogSearchView: View {
    @ObservedObject var catalog: CatalogPresentationModel
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    var onDownloadAlbum: (String, [CatalogSong]?) -> Void = { _, _ in }
    var albumDownloadState: (CatalogAlbum, Int?) -> ServerDownloadActionState = { _, _ in .idle }
    var onDownload: (CatalogSong) -> Void = { _ in }
    var downloadState: (CatalogSong) -> ServerDownloadActionState = { _ in .idle }
    var onAddToDevice: (CatalogSong) -> Void = { _ in }
    var deviceState: (CatalogSong) -> DeviceSaveState = { _ in .unavailable(.notInLibrary) }
    var onBrowse: (String) -> Void = { _ in }
    /// Starts loading charts and Discover suggestions for the shelves under Browse.
    var loadSuggestions: () -> Void = {}
    /// The drawer layout's Browse grid; replaces the built-in shortcuts while the field is empty.
    var browse: AnyView? = nil
    @Environment(\.openURL) private var openURL
    @State private var recommended: [CatalogSong] = []
    @State private var recommendationSeeds: [String] = []
    @State private var recommendationsLoading = false
    @State private var recommendationGeneration = 0
    @State private var showsAllRecommended = false

    private struct RecommendationRequest: Equatable {
        let session: DeviceSession?
        let generation: Int
    }

    private enum SearchCategory: String, CaseIterable {
        case songs, artists, albums
    }

    @State private var category: SearchCategory = .songs
    @State private var query = ""
    @State private var queueMessage: LocalizedStringKey?
    @State private var link = ""
    @State private var pendingAlbumAdd: PendingAlbumAdd?
    @FocusState private var searchFocused: Bool
    @Environment(\.downtifyPalette) private var palette

    init(catalog: CatalogPresentationModel, library: LibraryPresentationModel,
         playback: PlaybackController,
         onDownloadAlbum: @escaping (String, [CatalogSong]?) -> Void = { _, _ in },
         albumDownloadState: @escaping (CatalogAlbum, Int?) -> ServerDownloadActionState = { _, _ in .idle },
         onDownload: @escaping (CatalogSong) -> Void = { _ in },
         downloadState: @escaping (CatalogSong) -> ServerDownloadActionState = { _ in .idle },
         onAddToDevice: @escaping (CatalogSong) -> Void = { _ in },
         deviceState: @escaping (CatalogSong) -> DeviceSaveState = { _ in .unavailable(.notInLibrary) },
         onBrowse: @escaping (String) -> Void = { _ in },
         loadSuggestions: @escaping () -> Void = {},
         browse: AnyView? = nil) {
        self.catalog = catalog
        self.library = library
        self.playback = playback
        self.onDownloadAlbum = onDownloadAlbum
        self.albumDownloadState = albumDownloadState
        self.onDownload = onDownload
        self.downloadState = downloadState
        self.onAddToDevice = onAddToDevice
        self.deviceState = deviceState
        self.onBrowse = onBrowse
        self.loadSuggestions = loadSuggestions
        self.browse = browse
    }

    /// Catalog albums on screen that may need a provider track count to be recognised as owned.
    private var catalogAlbumRows: [CatalogAlbum] {
        var albums: [CatalogAlbum] = []
        switch catalog.searchAlbumsState {
        case .loaded(let value), .partial(let value, _): albums += value
        default: break
        }
        switch catalog.urlResolutionState {
        case .loaded(let value), .partial(let value, _): albums += value.albums
        default: break
        }
        return albums.filter(canRequestAlbumDownload)
    }

    private var albumCountLookupKey: [CatalogResultID] { catalogAlbumRows.map(\.id) + [CatalogResultID(source: "tracks", value: String(library.tracks.count))] }

    private func loadAlbumTrackCounts() {
        let membership = library.membership
        catalog.loadAlbumTrackCounts(for: catalogAlbumRows) {
            membership.hasAlbum(title: $0.title, artist: $0.artist)
        }
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
        VStack(alignment: category == .songs ? .leading : .center, spacing: 20) {
            if !palette.redesign("search") { searchPicker }

            if palette.redesign("search") {
                redesignSearchField
            } else {
                TextField("Songs, albums, artists", text: $query)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 5))
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityLabel("Search songs, albums, and artists")
                    .accessibilityIdentifier("catalog.searchField")
            }

            if palette.redesign("search") && !normalizedQuery.isEmpty { searchPicker }
            if !normalizedQuery.isEmpty {
                localResults
                catalogResults
            } else if palette.redesign("search") {
                if let browse { browse } else { browseShortcuts }
                suggestions
            } else {
                ContentUnavailableView("Search your music", systemImage: "magnifyingglass",
                                       description: Text("Search saved music and available catalog results."))
            }

            if catalog.externalCatalogAvailable {
                linkResolver
            }
        }
        .padding(palette.redesign("search") ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: category == .songs ? .leading : .center)
        .background(palette.redesign("search") ? Color.clear : palette.background)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchFocused = false }
            }
        }
        .task(id: normalizedQuery) {
            guard !normalizedQuery.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            catalog.search(normalizedQuery)
        }
        .onAppear { catalog.start() }
        .task(id: catalog.policyGeneration) { if palette.redesign("search") { loadSuggestions() } }
        .task(id: RecommendationRequest(session: catalog.session, generation: recommendationGeneration)) {
            guard palette.redesign("search") else { return }
            await loadRecommendations()
        }
        .task(id: albumCountLookupKey) { loadAlbumTrackCounts() }
        .confirmationDialog(pendingAlbumAdd?.confirmation.title ?? "", isPresented: isConfirmingAlbumAdd,
                            titleVisibility: .visible) {
            if let pending = pendingAlbumAdd {
                Button(pending.confirmation.confirmLabel) { onDownloadAlbum(pending.url, pending.resolved) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pending = pendingAlbumAdd { Text(pending.confirmation.message) }
        }
    }

    /// White field with a magnifier and a clear button, as in familiar streaming apps.
    private var redesignSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3.weight(.semibold))
            TextField("", text: $query, prompt: Text("What do you want to listen to?").foregroundStyle(Color(white: 0.4)))
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .accessibilityLabel("Search songs, albums, and artists")
                .accessibilityIdentifier("catalog.searchField")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).downtifyControlTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(Color.black)
        .tint(Color.black)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }

    @ViewBuilder private var searchPicker: some View {
            if palette.redesign("search") {
                HStack(spacing: 8) {
                    DowntifyChip(title: "Songs", isSelected: category == .songs) { category = .songs }
                    DowntifyChip(title: "Artists", isSelected: category == .artists) { category = .artists }
                    DowntifyChip(title: "Albums", isSelected: category == .albums) { category = .albums }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, -DowntifyStyle.Space.small)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Search category")
            } else {
                Picker("Search category", selection: $category) {
                    Text("Songs").tag(SearchCategory.songs)
                    Text("Artists").tag(SearchCategory.artists)
                    Text("Albums").tag(SearchCategory.albums)
                }
                .pickerStyle(.segmented)
            }

    }

    private var browseShortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse all").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                browseTile("For You", symbol: "sparkles", color: 0x203562)
                browseTile("Charts", symbol: "chart.line.uptrend.xyaxis", color: 0xE33600)
                browseTile("Finder", symbol: "safari", color: 0x27866F)
                browseTile("Similar", symbol: "waveform", color: 0x8863A8)
                browseTile("Podcasts", symbol: "mic.fill", color: 0x006450)
                browseTile("Downloads", symbol: "arrow.down.circle.fill", color: 0xB65B00)
            }
        }
    }

    private func tileColor(_ title: String, fallback: UInt32) -> UInt32 {
        palette.theme?.browseColors?[title].flatMap { UInt32($0, radix: 16) } ?? fallback
    }

    private func browseTile(_ title: String, symbol: String, color: UInt32) -> some View {
        Button { onBrowse(title) } label: {
            ZStack(alignment: .topLeading) {
                DowntifyStyle.adaptive(light: tileColor(title, fallback: color), dark: tileColor(title, fallback: color))
                Text(LocalizedStringKey(title)).font(.headline).padding(12)
                Image(systemName: symbol).font(.system(size: 42, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 8, y: 8).opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var localResults: some View {
        if category == .songs && !localSongs.isEmpty {
            sectionHeader("In your library")
            queueFeedback
            ForEach(localSongs) { track in
                NowPlayingReader { nowPlaying in
                    let isCurrent = nowPlaying.isCurrent(track)
                    HStack(spacing: 0) {
                    Button { playback.replaceQueue(localSongs, startingAt: localSongs.firstIndex(of: track) ?? 0) } label: {
                        HStack(spacing: palette.redesign("search") ? 12 : nil) {
                            if palette.redesign("search") { TrackArtwork(track: track, size: 48).accessibilityHidden(true) }
                            VStack(alignment: .leading, spacing: 3) {
                                currentTitle(track.title, isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying)
                                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if !palette.redesign("search") {
                                Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
                            }
                        }
                        .frame(minHeight: DowntifyStyle.minimumControlSize)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(track.title)")
                    .downtifyCurrentRowAccessibility(isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying)
                    queueMenu(for: .library(track), title: track.title, idKey: track.id)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        if category == .albums && !localAlbums.isEmpty {
            sectionHeader("Library albums")
            ForEach(localAlbums) { entry in
                if palette.redesign("search") {
                    NavigationLink(value: entry.context) { LibraryListRow(entry: entry) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: entry.context) {
                        Label("\(entry.title) · \(entry.artist)", systemImage: "square.stack")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
        if category == .artists && !localArtists.isEmpty {
            sectionHeader("Library artists")
            ForEach(localArtists) { entry in
                if palette.redesign("search") {
                    NavigationLink(value: entry.context) { LibraryListRow(entry: entry) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: entry.context) {
                        Label(entry.title, systemImage: "person")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder private var catalogResults: some View {
        if category == .songs {
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
        }

        if category == .albums {
            switch catalog.searchAlbumsState {
            case .loaded(let albums), .partial(let albums, _):
                if !albums.isEmpty {
                    sectionHeader("Catalog albums")
                    ForEach(albums) { album in
                        HStack {
                            NavigationLink { albumDetail(album) } label: {
                                if palette.redesign("search") {
                                    catalogAlbumRow(album)
                                } else {
                                    Label("\(album.title) · \(album.artist)", systemImage: "square.stack")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                            if canRequestAlbumDownload(album), let url = album.url {
                                serverAlbumDownloadButton(url: url, album: album)
                            }
                        }
                    }
                }
            case .loading: ProgressView("Searching catalog…")
            case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }

        if category == .artists {
            switch catalog.searchArtistsState {
            case .loaded(let artists), .partial(let artists, _):
                if !artists.isEmpty {
                    sectionHeader("Catalog artists")
                    ForEach(artists) { artist in
                        NavigationLink { artistDetail(artist) } label: {
                            HStack(spacing: 12) {
                                artistArtwork(artist.coverURL)
                                if palette.redesign("search") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(artist.name).lineLimit(1)
                                        Text("Artist").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(artist.name)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            case .loading: ProgressView("Searching catalog…")
            case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }

    private func albumDetail(_ album: CatalogAlbum) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(album.artist).font(.headline).foregroundStyle(.secondary)
                if finderAlbumID(album) != nil {
                    switch catalog.finderAlbumState {
                    case .loaded(let details), .partial(let details, _):
                        songResults(details.tracks, queueAlbum: true)
                    case .loading, .idle: ProgressView("Loading album…")
                    case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
                    case .empty: Text("No songs found.").foregroundStyle(.secondary)
                    }
                } else if let url = album.url {
                    albumResolutionDetails(url: url)
                } else {
                    Text("Album details are unavailable.").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .downtifyScrollEndClearance()
        .background(palette.background)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let id = finderAlbumID(album) { catalog.loadFinderAlbum(id: id) }
            else if let url = album.url { catalog.loadAlbumTracks(url: url) }
        })
    }

    private func artistDetail(_ artist: CatalogArtist) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if finderArtistID(artist) != nil {
                    switch catalog.finderArtistState {
                    case .loaded(let details), .partial(let details, _):
                        if !details.bio.isEmpty { Text(details.bio).font(.subheadline) }
                        if case .loaded(let songs) = catalog.finderArtistSongsState, !songs.isEmpty {
                            songResults(songs)
                        } else {
                            songResults(details.topSongs)
                        }
                    case .loading, .idle: ProgressView("Loading artist…")
                    case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
                    case .empty: Text("Artist details are unavailable.").foregroundStyle(.secondary)
                    }
                    switch catalog.finderArtistAlbumsState {
                    case .loaded(let albums), .partial(let albums, _):
                        if !albums.isEmpty { sectionHeader("Albums") }
                        ForEach(albums) { album in
                            NavigationLink { albumDetail(album) } label: {
                                Label(album.title, systemImage: "square.stack")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                    case .loading: ProgressView("Loading artist albums…")
                    case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                } else if artist.url != nil {
                    resolutionDetails
                } else {
                    Text("Artist details are unavailable.").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .downtifyScrollEndClearance()
        .background(palette.background)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let id = finderArtistID(artist) { catalog.loadFinderArtist(id: id, name: artist.name) }
            else if let url = artist.url { catalog.resolveURL(url) }
        }
    }

    @ViewBuilder private var resolutionDetails: some View {
        switch catalog.urlResolutionState {
        case .loaded(let resolution), .partial(let resolution, _):
            songResults(resolution.tracks)
            if !resolution.albums.isEmpty { sectionHeader("Albums") }
            ForEach(resolution.albums) { album in
                NavigationLink { albumDetail(album) } label: {
                    Label(album.title, systemImage: "square.stack")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        case .loading, .idle: ProgressView("Resolving link…")
        case .failed(let message), .unavailable(let message): Text(message).foregroundStyle(.secondary)
        case .empty: Text("No results found.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func albumResolutionDetails(url: String) -> some View {
        switch catalog.albumTracksState {
        case .loaded(let tracks), .partial(let tracks, _):
            if tracks.isEmpty { Text("No songs found.").foregroundStyle(.secondary) }
            else { songResults(tracks, queueAlbum: true) }
        case .loading, .idle: ProgressView("Loading album tracks…")
        case .failed(let message), .unavailable(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { catalog.loadAlbumTracks(url: url) }
            }
        case .empty: Text("No songs found.").foregroundStyle(.secondary)
        }
    }

    private func finderAlbumID(_ album: CatalogAlbum) -> String? {
        let id = album.deezerAlbumID ?? (album.source.lowercased() == "deezer" ? album.albumID : nil)
        return id.flatMap { isDecimalID($0) ? $0 : nil }
    }

    private func finderArtistID(_ artist: CatalogArtist) -> String? {
        let id = artist.deezerID ?? (artist.source.lowercased() == "deezer" ? artist.artistID : nil)
        return id.flatMap { isDecimalID($0) ? $0 : nil }
    }

    private func isDecimalID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) }
    }

    @ViewBuilder private func songResults(_ songs: [CatalogSong], queueAlbum: Bool = false) -> some View {
        if !songs.isEmpty {
            sectionHeader("Catalog songs")
            queueFeedback
            ForEach(songs) { song in
                NowPlayingReader { nowPlaying in
                    let isCurrent = nowPlaying.isCurrent(song)
                    HStack(spacing: 10) {
                        Button {
                            if queueAlbum {
                                let items = songs.map { PlaybackItem.resolving($0, in: library.tracks) }
                                playback.replaceQueue(items, startingAt: songs.firstIndex(of: song) ?? 0)
                                return
                            }
                            if song.source == "library" {
                                guard let track = song.libraryTrack(in: library.tracks) else { return }
                                playback.replaceQueue([.library(track)])
                                return
                            }
                            playback.replaceQueue([PlaybackItem.resolving(song, in: library.tracks)])
                        } label: {
                            HStack(spacing: palette.redesign("search") ? 12 : nil) {
                                if palette.redesign("search") { songArtwork(song) }
                                VStack(alignment: .leading, spacing: 3) {
                                    currentTitle(song.title, isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying)
                                    Text([song.artist, song.albumName].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if !palette.redesign("search") {
                                    Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
                                }
                            }
                            .frame(minHeight: DowntifyStyle.minimumControlSize)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(song.title)")
                        .downtifyCurrentRowAccessibility(isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying)
                        .accessibilityIdentifier("catalog.result.\(song.id)")
                        .disabled(song.source == "library" && song.libraryTrack(in: library.tracks) == nil)
                        if song.source != "library", catalog.externalCatalogAvailable {
                            serverDownloadButton(for: song)
                        }
                        deviceButton(for: song)
                        if let item = queueItem(for: song) {
                            queueMenu(for: item, title: song.title, idKey: song.id.description)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func currentTitle(_ title: String, isCurrent: Bool, isPlaying: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isCurrent { NowPlayingBadge(isPlaying: isPlaying) }
            Text(title).font(.body.weight(.semibold))
                .foregroundStyle(isCurrent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.primary))
        }
    }

    /// The result's cover, or the library copy's cover when the catalog has none.
    @ViewBuilder private func songArtwork(_ song: CatalogSong) -> some View {
        let url = song.coverURL ?? song.previewURL
        if url == nil, song.source == "library", let track = song.libraryTrack(in: library.tracks) {
            TrackArtwork(track: track, size: 48).accessibilityHidden(true)
        } else {
            CatalogCoverImage(imageURL: url, size: 48)
        }
    }

    private func catalogAlbumRow(_ album: CatalogAlbum) -> some View {
        HStack(spacing: 12) {
            CatalogCoverImage(imageURL: album.coverURL, size: 48, symbol: "opticaldisc")
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).lineLimit(1)
                Text(album.artist.isEmpty ? String(localized: "Album") : String(localized: "Album · \(album.artist)"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Suggestions under Browse

    private func loaded<Value>(_ state: CatalogLoadState<Value>) -> Value? {
        switch state {
        case .loaded(let value), .partial(let value, _): value
        default: nil
        }
    }

    private func unique<Item: Identifiable>(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Up to three seeds: the song playing now, then recently added library songs by other artists.
    private var recommendationSeedTracks: [(artist: String, track: String)] {
        var seeds: [(artist: String, track: String)] = []
        var artists = Set<String>()
        func add(artist: String, track: String) {
            let key = artist.lowercased()
            guard !artist.isEmpty, !track.isEmpty, artists.insert(key).inserted, seeds.count < 3 else { return }
            seeds.append((artist, track))
        }
        // Multi-artist credits ("A; B") are reduced to the lead artist so one act doesn't fill every seed.
        if let item = playback.queue.current?.item { add(artist: item.leadArtist, track: item.title) }
        for track in library.tracks.sorted(by: { $0.added > $1.added }) where seeds.count < 3 {
            add(artist: PlaybackItem.library(track).leadArtist, track: track.title)
        }
        return seeds
    }

    /// Songs similar to what this account listens to, minus anything already in the library.
    private func loadRecommendations() async {
        guard catalog.session != nil, catalog.supportsDiscover == true else {
            recommended = []
            return
        }
        let seeds = recommendationSeedTracks
        guard !seeds.isEmpty else { return }
        recommendationsLoading = true
        defer { if !Task.isCancelled { recommendationsLoading = false } }
        let catalog = self.catalog
        let lists = await withTaskGroup(of: (Int, [CatalogSong]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { @MainActor in
                    (index, (try? await catalog.similarSongs(artist: seed.artist, track: seed.track)) ?? [])
                }
            }
            var results = [[CatalogSong]](repeating: [], count: seeds.count)
            for await (index, tracks) in group { results[index] = tracks }
            return results
        }
        guard !Task.isCancelled else { return }
        // Interleave the seeds' lists so the first rows mix every seed.
        var merged: [CatalogSong] = []
        var seen = Set<String>()
        let longest = lists.map(\.count).max() ?? 0
        for position in 0..<longest {
            for list in lists where position < list.count {
                let song = list[position]
                let key = "\(song.artist.lowercased())|\(song.title.lowercased())"
                guard seen.insert(key).inserted, !library.membership.containsSong(song) else { continue }
                merged.append(song)
            }
        }
        recommended = Array(merged.prefix(30))
        recommendationSeeds = seeds.map(\.artist)
    }

    @ViewBuilder private var recommendedSection: some View {
        if !recommended.isEmpty || recommendationsLoading {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommended for you").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        if !recommendationSeeds.isEmpty {
                            Text("Based on \(recommendationSeeds.joined(separator: ", "))")
                                .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { showsAllRecommended = false; recommendationGeneration += 1 } label: {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)).downtifyControlTarget()
                    }
                    .buttonStyle(.plain)
                    .disabled(recommendationsLoading)
                    .accessibilityLabel("Refresh recommendations")
                }
                if recommendationsLoading && recommended.isEmpty {
                    ProgressView("Finding songs for you…").frame(maxWidth: .infinity, minHeight: 80)
                }
                let visible = showsAllRecommended ? recommended : Array(recommended.prefix(6))
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, song in
                    recommendedRow(song, index: index)
                }
                if recommended.count > 6 {
                    Button(showsAllRecommended ? String(localized: "Show less") : String(localized: "Show all")) {
                        showsAllRecommended.toggle()
                    }
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .overlay(Capsule().strokeBorder(DowntifyStyle.secondaryText, lineWidth: 1))
                    .frame(minHeight: DowntifyStyle.minimumControlSize)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DowntifyStyle.Space.small)
        }
    }

    private func recommendedRow(_ song: CatalogSong, index: Int) -> some View {
        HStack(spacing: 10) {
            NowPlayingReader { nowPlaying in
                let isCurrent = nowPlaying.isCurrent(song)
                Button {
                    playback.replaceQueue(recommended.map { PlaybackItem.resolving($0, in: library.tracks) }, startingAt: index)
                } label: {
                    HStack(spacing: 12) {
                        CatalogCoverImage(imageURL: song.coverURL, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if isCurrent { NowPlayingBadge(isPlaying: nowPlaying.isPlaying) }
                                Text(song.title)
                                    .foregroundStyle(isCurrent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.primary))
                                    .lineLimit(1)
                            }
                            Text(song.artists.isEmpty ? song.artist : song.artists.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(DowntifyStyle.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(song.title) by \(song.artist)")
                .downtifyCurrentRowAccessibility(isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying)
            }
            if song.source != "library", catalog.externalCatalogAvailable {
                serverDownloadButton(for: song)
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        recommendedSection
        let charts = loaded(catalog.chartsState)
        let collections = [loaded(catalog.deezerCollectionsState), loaded(catalog.spotifyCollectionsState)].compactMap { $0 }
        let suggestedArtists = loaded(catalog.discoverArtistsState)?.artists ?? []
        let collectionAlbums = unique(collections.flatMap { $0.albums + $0.moreAlbums })
        let playlists = unique((charts?.playlists ?? []) + collections.flatMap(\.playlists))
        if !suggestedArtists.isEmpty {
            suggestionShelf("Suggested artists") {
                ForEach(suggestedArtists) { artist in
                    NavigationLink { artistDetail(artist) } label: {
                        RemoteArtworkCard(title: artist.name, subtitle: String(localized: "Artist"), imageURL: artist.coverURL,
                                          round: true, symbol: "music.mic")
                    }.buttonStyle(.plain)
                }
            }
        }
        if !collectionAlbums.isEmpty {
            suggestionShelf("Albums for you") { albumCards(collectionAlbums) }
        }
        if let tracks = charts?.tracks, !tracks.isEmpty {
            suggestionShelf("Popular songs") {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, song in
                    Button {
                        playback.replaceQueue(tracks.map { PlaybackItem.resolving($0, in: library.tracks) }, startingAt: index)
                    } label: {
                        RemoteArtworkCard(title: song.title, subtitle: song.artists.isEmpty ? song.artist : song.artists.joined(separator: ", "),
                                          imageURL: song.coverURL)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays this song")
                }
            }
        }
        if let albums = charts?.albums, !albums.isEmpty {
            suggestionShelf("Popular albums") { albumCards(albums) }
        }
        if !playlists.isEmpty {
            suggestionShelf("Playlists for you") {
                ForEach(playlists) { playlist in
                    Button {
                        if let value = playlist.url, let url = URL(string: value), url.scheme?.lowercased() == "https" { openURL(url) }
                    } label: {
                        RemoteArtworkCard(title: playlist.name, subtitle: playlist.owner ?? "", imageURL: playlist.coverURL,
                                          symbol: "music.note.list")
                    }
                    .buttonStyle(.plain)
                    .disabled(playlist.url == nil)
                    .accessibilityHint("Opens the playlist with its provider")
                }
            }
        }
        if let artists = charts?.artists, !artists.isEmpty {
            suggestionShelf("Popular artists") {
                ForEach(artists) { artist in
                    NavigationLink { artistDetail(artist) } label: {
                        RemoteArtworkCard(title: artist.name, subtitle: String(localized: "Artist"), imageURL: artist.coverURL,
                                          round: true, symbol: "music.mic")
                    }.buttonStyle(.plain)
                }
            }
        }
        if catalog.chartsState == .loading || catalog.discoverArtistsState == .loading {
            ProgressView("Loading suggestions…").frame(maxWidth: .infinity)
        }
    }

    private func albumCards(_ albums: [CatalogAlbum]) -> some View {
        ForEach(albums) { album in
            NavigationLink { albumDetail(album) } label: {
                RemoteArtworkCard(title: album.title, subtitle: album.artist, imageURL: album.coverURL, symbol: "opticaldisc")
            }.buttonStyle(.plain)
        }
    }

    private func suggestionShelf<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DowntifyStyle.Space.small)
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
                            NavigationLink { albumDetail(album) } label: {
                                Label("\(album.title) · \(album.artist)", systemImage: "square.stack")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                            if canRequestAlbumDownload(album), let url = album.url {
                                serverAlbumDownloadButton(url: url, album: album)
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

    /// Catalog artist photo; only https covers load, anything else shows the person symbol.
    @ViewBuilder private func artistArtwork(_ value: String?) -> some View {
        Group {
            if let value, let url = URL(string: value), url.scheme?.lowercased() == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { artistArtworkPlaceholder }
                }
            } else {
                artistArtworkPlaceholder
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var artistArtworkPlaceholder: some View {
        Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
            .frame(width: 48, height: 48).background(palette.background)
    }

    @ViewBuilder private var queueFeedback: some View {
        if let queueMessage { Text(queueMessage).font(.subheadline).foregroundStyle(.secondary) }
    }

    /// Library-sourced catalog results that no longer resolve to a library track cannot be queued.
    private func queueItem(for song: CatalogSong) -> PlaybackItem? {
        if song.source == "library" {
            return song.libraryTrack(in: library.tracks).map(PlaybackItem.library)
        }
        return PlaybackItem.resolving(song, in: library.tracks)
    }

    private func queueMenu(for item: PlaybackItem, title: String, idKey: String) -> some View {
        Menu {
            Button("Play next", systemImage: "text.insert") {
                playback.playNext([item])
                queueMessage = "Added to play next"
                AccessibilityNotification.Announcement(String(localized: "Added to play next")).post()
            }
            .accessibilityIdentifier("catalog.menu.playNext.\(idKey)")
            Button("Add to queue", systemImage: "text.append") {
                playback.append([item])
                queueMessage = "Added to queue"
                AccessibilityNotification.Announcement(String(localized: "Added to queue")).post()
            }
            .accessibilityIdentifier("catalog.menu.addToQueue.\(idKey)")
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel("More options for \(title)")
        .accessibilityIdentifier("catalog.menu.\(idKey)")
    }

    @ViewBuilder private func deviceButton(for song: CatalogSong) -> some View {
        let state = deviceState(song)
        if state != .unavailable(.notInLibrary) {
            MediaActionButton(presentation: .device(state, itemTitle: song.title)) { onAddToDevice(song) }
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder private func serverDownloadButton(for song: CatalogSong) -> some View {
        MediaActionButton(presentation: .library(downloadState(song), itemTitle: song.title)) { onDownload(song) }
            .frame(width: 44, height: 44)
    }

    private func canRequestAlbumDownload(_ album: CatalogAlbum) -> Bool {
        guard catalog.externalCatalogAvailable, let url = album.url else { return false }
        return ServerDownloadQueue.isYouTubeMusicAlbumURL(url)
    }

    @ViewBuilder private func serverAlbumDownloadButton(url: String, album: CatalogAlbum) -> some View {
        let resolved = resolvedAlbumTracks(for: url)
        let trackCount = album.trackCount ?? catalog.albumTrackCounts[album.id] ?? resolved?.count
        MediaActionButton(presentation: .library(albumDownloadState(album, trackCount),
                                                 itemTitle: album.title)) {
            if let confirmation = AlbumAddConfirmation.make(albumTitle: album.title, trackCount: trackCount) {
                pendingAlbumAdd = PendingAlbumAdd(url: url, resolved: resolved, confirmation: confirmation)
            } else {
                onDownloadAlbum(url, resolved)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var isConfirmingAlbumAdd: Binding<Bool> {
        Binding(get: { pendingAlbumAdd != nil }, set: { if !$0 { pendingAlbumAdd = nil } })
    }

    private func resolvedAlbumTracks(for url: String) -> [CatalogSong]? {
        switch catalog.finderAlbumState {
        case .loaded(let details), .partial(let details, _):
            if details.album.url == url { return details.tracks }
        default: break
        }
        switch catalog.urlResolutionState {
        case .loaded(let resolution), .partial(let resolution, _):
            return resolution.albums.count == 1 && resolution.albums.first?.url == url ? resolution.tracks : nil
        default: return nil
        }
    }
}
