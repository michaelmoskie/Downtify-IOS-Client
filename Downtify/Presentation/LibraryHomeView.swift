import SwiftUI

struct LibraryHomeView: View {
    let server: SessionPresentationCoordinator.ServerSummary
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @Binding var appearance: DowntifyAppearance
    let connection: ConnectionService
    let signOut: @MainActor () async throws -> Void
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("library.sort") private var sort = LibrarySort.recentlyAdded
    @AppStorage("library.descending") private var descending = true
    @AppStorage("library.grid") private var grid = true
    @State private var category = Category.albums
    @State private var searchText = ""
    @State private var showingSignOutConfirmation = false
    @State private var signOutError: String?
    @State private var tab = Tab.home

    private enum Tab { case home, library, search, discover, podcasts }
    private enum Category: String, CaseIterable, Identifiable {
        case songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists"
        var id: Self { self }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                browsePage(title: "Home") { homeContent }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)

            NavigationStack {
                browsePage(title: "Library") { libraryContent }
                    .searchable(text: $searchText, prompt: "Filter your library")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Library", systemImage: "books.vertical") }.tag(Tab.library)

            NavigationStack {
                browsePage(title: "Search") { searchContent }
                    .searchable(text: $searchText, prompt: "Search your library")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)

            NavigationStack {
                browsePage(title: "Discover") { discoveryContent }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Discover", systemImage: "sparkles") }.tag(Tab.discover)

            PodcastsView(connection: connection, playback: playback)
                .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
                .tabItem { Label("Podcasts", systemImage: "mic") }.tag(Tab.podcasts)
        }
        .confirmationDialog("Sign out of \(server.name)?", isPresented: $showingSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    do { try await signOut() } catch { signOutError = "Could not sign out. Please try again." }
                }
            }
        } message: {
            Text("You can reconnect to this server at any time.")
        }
        .alert("Sign out failed", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button("OK", role: .cancel) { signOutError = nil }
        } message: { Text(signOutError ?? "") }
    }

    private func browsePage<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                syncStatus
                content()
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refresh() }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .toolbarBackground(palette.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { accountMenu }
        }
        .navigationDestination(for: LibraryContext.self) { context in
            LibraryContextView(context: context, library: library, playback: playback)
        }
    }

    private var accountMenu: some View {
        Menu {
            if let username = server.username {
                Label("Signed in as \(username)", systemImage: "person.crop.circle")
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(DowntifyAppearance.allCases) { option in Text(option.label).tag(option) }
            }
            Button("Refresh library", systemImage: "arrow.clockwise") { Task { await refresh() } }
            Button("Sign out", role: .destructive) { showingSignOutConfirmation = true }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account options")
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var likedEntry: LibraryBrowseEntry {
        LibraryBrowseEntry(id: "", context: .liked, title: String(localized: "Liked songs"), artist: "",
                           added: 0, count: collections.likedIDs?.count ?? 0,
                           artwork: collections.likedIDs?.lazy.compactMap { library.catalog.tracksByID[$0] }.first(where: \.hasCover))
    }

    private func playlistEntry(_ playlist: LibraryPlaylist) -> LibraryBrowseEntry {
        LibraryBrowseEntry(id: playlist.id, context: .playlist(playlist.name), title: playlist.title,
                           artist: playlist.mine == false ? playlist.owner ?? "" : "", added: 0,
                           count: playlist.trackIDs.count,
                           artwork: playlist.trackIDs.lazy.compactMap { library.catalog.tracksByID[$0] }.first(where: \.hasCover),
                           playlistCover: playlist.cover)
    }

    private func entry(_ context: LibraryContext) -> LibraryBrowseEntry? {
        switch context {
        case .album(let id): library.catalog.albumsByID[id]
        case .artist(let id): library.catalog.artistsByID[id]
        case .playlist(let name): collections.playlist(named: name).map(playlistEntry)
        case .liked: likedEntry
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        let newest = library.latestAlbums
        let recents = collections.recents.compactMap(entry)
        let fallback = (likedEntry.count > 0 ? [likedEntry] : []) + newest
        let jump = recents.isEmpty ? Array(fallback.prefix(12)) : recents
        let favorites = LibrarySort.alphabetical.ordered(
            (collections.playlists ?? []).filter { $0.favorite == true && $0.liked != true }.map(playlistEntry),
            descending: false
        )
        if !jump.isEmpty { shelf("Jump back in", entries: jump) }
        if !newest.isEmpty { shelf("Recently added", entries: newest) }
        if !favorites.isEmpty { shelf("Favorite playlists", entries: favorites) }
        if jump.isEmpty && newest.isEmpty && favorites.isEmpty {
            if library.tracks.isEmpty { emptyTracks }
            else {
                DowntifyUnavailableView(title: "Nothing to jump back into yet", symbol: "clock",
                                        message: Text("Play an artist or collection to see it here."))
            }
        }
        if collections.playlistState == .unavailable || collections.likesState == .unavailable {
            collectionStatus(.unavailable, cached: collections.playlists != nil || collections.likedIDs != nil,
                             title: "Likes or playlists could not be refreshed.")
        }
    }

    private func shelf(_ title: LocalizedStringKey, entries: [LibraryBrowseEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: entries, grid: !dynamicTypeSize.isAccessibilitySize)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Library category", selection: $category) {
                ForEach(Category.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            Picker("Library category", selection: $category) {
                ForEach(Category.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
        }
        HStack {
            if category != .playlists { sortMenu }
            Spacer()
            if category != .songs && !dynamicTypeSize.isAccessibilitySize {
                Button { grid.toggle() } label: {
                    Image(systemName: grid ? "list.bullet" : "square.grid.2x2").downtifyControlTarget()
                }
                .accessibilityLabel(grid ? "Show as list" : "Show as grid")
            }
        }
        switch category {
        case .songs:
            let tracks = library.songs(sort: sort, descending: descending, query: query)
            if library.tracks.isEmpty { emptyTracks }
            else if tracks.isEmpty { ContentUnavailableView.search(text: searchText) }
            else { LibraryTrackList(tracks: tracks, context: nil, playback: playback) }
        case .albums:
            browseGroups(Array(library.catalog.albumsByID.values), emptyTitle: "No albums")
        case .artists:
            browseGroups(Array(library.catalog.artistsByID.values), emptyTitle: "No artists")
        case .playlists:
            playlistContent
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if query.isEmpty {
            DowntifyUnavailableView(title: "Search your library", symbol: "magnifyingglass",
                                    message: Text("Search saved songs, albums, and artists. Server catalog search is not available in the verified device contract."))
        } else if library.tracks.isEmpty {
            emptyTracks
        } else {
            let matchingTracks = LibraryTrackOrdering.matching(library.tracks, query: query)
            let albums = matching(Array(library.catalog.albumsByID.values))
            let artists = matching(Array(library.catalog.artistsByID.values))
            if matchingTracks.isEmpty && albums.isEmpty && artists.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                if !matchingTracks.isEmpty {
                    Text("Songs").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LibraryTrackList(tracks: matchingTracks, context: nil, playback: playback)
                }
                if !albums.isEmpty {
                    Text("Albums").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LibraryEntryList(entries: sort.ordered(albums, descending: descending), grid: false)
                }
                if !artists.isEmpty {
                    Text("Artists").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LibraryEntryList(entries: sort.ordered(artists, descending: descending), grid: false)
                }
            }
        }
    }

    private var discoveryContent: some View {
        VStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
            Label("Catalog discovery is unavailable", systemImage: "sparkles")
                .font(.title3.bold())
            Text("The audited server contract does not define a Discover catalog endpoint. Your saved library remains available in Library and Search.")
                .foregroundStyle(.secondary)
            Divider()
            Label("Similar tracks are unavailable", systemImage: "waveform.path")
                .font(.headline)
            Text("Android uses GET /api/similar/tracks, which is outside the mobile device contract. Downtify does not request it without a verified server contract.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { sort }, set: {
                guard sort != $0 else { return }
                sort = $0
                descending = $0.descendingByDefault
            })) {
                ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
            }
            Picker("Sort order", selection: $descending) {
                Text("Ascending").tag(false)
                Text("Descending").tag(true)
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down").padding(.vertical, 10)
        }
        .accessibilityLabel("Library sort, \(sort.label)")
    }

    @ViewBuilder
    private func browseGroups(_ entries: [LibraryBrowseEntry], emptyTitle: LocalizedStringKey) -> some View {
        let filtered = matching(entries)
        if library.tracks.isEmpty { emptyTracks }
        else if filtered.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: searchText) }
        else if filtered.isEmpty { ContentUnavailableView(emptyTitle, systemImage: "music.note") }
        else {
            LibraryEntryList(entries: sort.ordered(filtered, descending: descending),
                             grid: grid && !dynamicTypeSize.isAccessibilitySize)
        }
    }

    private func matching(_ entries: [LibraryBrowseEntry]) -> [LibraryBrowseEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }
    }

    @ViewBuilder
    private var playlistContent: some View {
        collectionStatus(collections.playlistState, cached: collections.playlists != nil, title: "Playlists could not be refreshed.")
        if collections.likesState == .unavailable && collections.likedIDs == nil {
            collectionStatus(.unavailable, cached: false, title: "Liked songs are unavailable.")
        }
        let lists = (collections.playlists ?? []).filter { $0.liked != true }
        let own = matching(lists.filter { $0.mine != false }.map(playlistEntry))
        let shared = matching(lists.filter { $0.mine == false && $0.sharedWithMe == true }.map(playlistEntry))
        let others = matching(lists.filter { $0.mine == false && $0.sharedWithMe != true }.map(playlistEntry))
        let liked = collections.likedIDs == nil ? [] : matching([likedEntry])
        let favoriteIDs = Set(lists.filter { $0.favorite == true }.map(\.id))
        let pinned = own.filter { favoriteIDs.contains($0.id) } + liked + own.filter { !favoriteIDs.contains($0.id) }
        let useGrid = grid && !dynamicTypeSize.isAccessibilitySize
        if !pinned.isEmpty { LibraryEntryList(entries: pinned, grid: useGrid) }
        if !shared.isEmpty {
            Text("Shared with me").font(.headline).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: shared, grid: useGrid)
        }
        if !others.isEmpty {
            Text("Public playlists").font(.headline).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: others, grid: useGrid)
        }
        if pinned.isEmpty && shared.isEmpty && others.isEmpty && collections.playlistState == .ready {
            if !query.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView("No playlists", systemImage: "music.note.list")
            }
        }
    }

    @ViewBuilder
    private func collectionStatus(_ state: LibraryCollectionsModel.State, cached: Bool, title: LocalizedStringKey) -> some View {
        if state == .loading && !cached {
            ProgressView("Loading playlists and likes…")
        } else if state == .unavailable {
            Label(title, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry") { Task { await collections.refresh() } }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if library.state == .refreshing { ProgressView("Refreshing library…") }
        if !library.tracks.isEmpty {
            switch library.state {
            case .cachedError(let message), .storageFailure(let message):
                Label(message, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Showing saved music.").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var emptyTracks: some View {
        switch library.state {
        case .loading, .refreshing:
            ProgressView("Loading your library…").frame(maxWidth: .infinity, minHeight: 150)
        case .empty, .ready:
            DowntifyUnavailableView(title: "Your library is empty", symbol: "music.note.list",
                                    message: Text("Music saved on this server will appear here."),
                                    retry: { Task { await refresh() } })
        case .cachedError(let message), .storageFailure(let message):
            DowntifyUnavailableView(title: "Library unavailable", symbol: "exclamationmark.triangle",
                                    message: Text(message), retry: { Task { await refresh() } })
        }
    }

    private func refresh() async {
        async let music: Void = library.refresh()
        async let lists: Void = collections.refresh()
        _ = await (music, lists)
    }
}

private struct LibraryEntryList: View {
    let entries: [LibraryBrowseEntry]
    let grid: Bool

    var body: some View {
        if grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 12)], spacing: 12) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.context) {
                        VStack(alignment: .leading, spacing: 6) {
                            artwork(entry, size: 108)
                            Text(entry.title).font(.headline).lineLimit(2)
                            Text(subtitle(entry)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.context) {
                        DowntifyMediaRow(title: entry.title, subtitle: subtitle(entry)) {
                            artwork(entry, size: 54)
                        } accessory: {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subtitle(_ entry: LibraryBrowseEntry) -> String {
        if !entry.artist.isEmpty { return entry.artist }
        return entry.count == 1 ? String(localized: "1 song") : String(localized: "\(entry.count) songs")
    }

    @ViewBuilder
    private func artwork(_ entry: LibraryBrowseEntry, size: CGFloat) -> some View {
        if entry.artwork != nil || entry.playlistCover?.isEmpty == false {
            TrackArtwork(track: entry.artwork, size: size, playlistCover: entry.playlistCover)
        } else {
            let symbol: String = switch entry.context {
            case .artist: "music.mic"
            case .album: "opticaldisc"
            case .playlist: "music.note.list"
            case .liked: "heart.fill"
            }
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
    }
}

private struct LibraryContextView: View {
    let context: LibraryContext
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var downloads: OfflineDownloads
    @Environment(\.downtifyPalette) private var palette
    @State private var confirmingDownload = false
    @State private var downloadMessage: String?

    private var playlist: LibraryPlaylist? {
        guard case .playlist(let name) = context else { return nil }
        return collections.playlist(named: name)
    }

    private var title: String {
        switch context {
        case .album(let id): library.catalog.albumsByID[id]?.title ?? String(localized: "Album")
        case .artist(let id): library.catalog.artistsByID[id]?.title ?? String(localized: "Artist")
        case .playlist: playlist?.title ?? String(localized: "Playlist")
        case .liked: String(localized: "Liked songs")
        }
    }

    var body: some View {
        let tracks = library.catalog.tracks(in: context, likedIDs: collections.likedIDs ?? [], playlist: playlist)
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                if let playlist, playlist.mine == false, let owner = playlist.owner, !owner.isEmpty {
                    Text("By \(owner)").foregroundStyle(.secondary)
                }
                if case .album(let id) = context, let album = library.catalog.albumsByID[id], !album.artist.isEmpty {
                    if let artistID = tracks.first?.artistID, library.catalog.artistsByID[artistID] != nil {
                        NavigationLink(album.artist, value: LibraryContext.artist(artistID))
                    } else {
                        Text(album.artist).foregroundStyle(.secondary)
                    }
                }
                if let cover = tracks.first(where: \.hasCover), playlist?.cover?.isEmpty != false {
                    TrackArtwork(track: cover, size: 160)
                } else if let cover = playlist?.cover, !cover.isEmpty {
                    TrackArtwork(track: tracks.first(where: \.hasCover), size: 160, playlistCover: cover)
                }
                actions(tracks)
                if let downloadMessage { Text(downloadMessage).font(.subheadline).foregroundStyle(.secondary) }
                status(tracks)
                if case .artist(let id) = context {
                    let albums = library.catalog.albums(for: id)
                    if !albums.isEmpty {
                        Text("Albums").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        LibraryEntryList(entries: albums, grid: false)
                    }
                }
                if !tracks.isEmpty {
                    Text("Songs").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    LibraryTrackList(tracks: tracks, context: context, playback: playback)
                } else if let error = collections.actionError {
                    Text(error).foregroundStyle(.secondary)
                    Button("Dismiss") { collections.clearError() }
                }
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            async let music: Void = library.refresh()
            async let lists: Void = collections.refresh()
            _ = await (music, lists)
        }
        .navigationTitle(title)
        .background(palette.background.ignoresSafeArea())
        .confirmationDialog("Download these songs for offline playback?", isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Download songs") {
                var failures = 0
                var queued = Set<String>()
                for track in tracks where queued.insert(track.id).inserted {
                    do { try downloads.enqueue(track) } catch { failures += 1 }
                }
                downloadMessage = failures == 0 ? "Offline downloads requested." : "Some downloads could not be started."
            }
        }
    }

    private func actions(_ tracks: [LibraryTrack]) -> some View {
        HStack {
            if !tracks.isEmpty {
                Button("Play", systemImage: "play.fill") {
                    collections.record(context)
                    playback.setShuffle(false)
                    playback.replaceQueue(tracks)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    collections.record(context)
                    playback.replaceQueue(tracks, startingAt: Int.random(in: tracks.indices))
                    playback.setShuffle(true)
                } label: {
                    Image(systemName: "shuffle").downtifyControlTarget()
                }
                .accessibilityLabel("Shuffle songs")
            }
            Spacer()
            if let playlist, let favorite = playlist.favorite {
                Button {
                    Task { await collections.toggleFavorite(playlist.name) }
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star").downtifyControlTarget()
                }
                .disabled(collections.mutationBusy)
                .accessibilityLabel(favorite ? "Remove playlist from favorites" : "Favorite playlist")
            }
            if !tracks.isEmpty {
                Menu {
                    Button("Add songs to queue", systemImage: "text.append") { playback.append(tracks) }
                    Button("Download songs", systemImage: "arrow.down.circle") { confirmingDownload = true }
                } label: {
                    Image(systemName: "ellipsis.circle").downtifyControlTarget()
                }
                .accessibilityLabel("Collection actions")
            }
        }
    }

    @ViewBuilder
    private func status(_ tracks: [LibraryTrack]) -> some View {
        let collectionState: LibraryCollectionsModel.State? = switch context {
        case .playlist: collections.playlistState
        case .liked: collections.likesState
        default: nil
        }
        let hasCache = context == .liked ? collections.likedIDs != nil : playlist != nil
        if collectionState == .unavailable {
            Label(hasCache ? "Showing saved collection. Refresh failed." : "Collection unavailable.",
                  systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            Button("Retry") { Task { await collections.refresh() } }
        } else if collectionState == .loading && !hasCache {
            ProgressView("Loading collection…")
        }
        switch library.state {
        case .cachedError(let message), .storageFailure(let message):
            Label(message, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry library refresh") { Task { await library.refresh() } }
        case .loading, .refreshing:
            if tracks.isEmpty { ProgressView("Loading songs…") }
        case .empty, .ready:
            if tracks.isEmpty && (collectionState == nil || collectionState == .ready || hasCache) {
                ContentUnavailableView("No songs available", systemImage: "music.note")
            }
        }
    }
}

private struct LibraryTrackList: View {
    let tracks: [LibraryTrack]
    let context: LibraryContext?
    let playback: PlaybackController
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var downloads: OfflineDownloads
    @Environment(\.downtifyPalette) private var palette
    @State private var downloadMessage: String?

    var body: some View {
        let downloadByID = Dictionary(downloads.currentDownloads.map { ($0.track.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        if let error = collections.actionError {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            Button("Dismiss") { collections.clearError() }
        }
        if let downloadMessage { Text(downloadMessage).font(.subheadline).foregroundStyle(.secondary) }
        LazyVStack(spacing: 0) {
            ForEach(tracks.indices, id: \.self) { index in
                let track = tracks[index]
                let liked = collections.likedSet.contains(track.id)
                HStack(spacing: 0) {
                    Button {
                        if let context { collections.record(context) }
                        playback.replaceQueue(tracks, startingAt: index)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(track.accessibleMetadata))
                    .accessibilityValue(spokenDuration(track.duration))
                    .accessibilityHint("Play this song and replace the current queue")
                    Menu {
                        if collections.likedIDs != nil {
                            Button(liked ? "Unlike song" : "Like song", systemImage: liked ? "heart.slash" : "heart") {
                                Task { await collections.toggleLike(track) }
                            }
                            .disabled(collections.mutationBusy)
                        }
                        Button("Add to queue", systemImage: "text.append") { playback.append([track]) }
                        downloadAction(track, record: downloadByID[track.id])
                    } label: {
                        HStack(spacing: 0) {
                            if liked {
                                Image(systemName: "heart.fill").font(.caption).foregroundStyle(DowntifyStyle.accent)
                            }
                            Image(systemName: "ellipsis")
                        }
                        .downtifyControlTarget()
                    }
                    .accessibilityLabel("Actions for \(track.displayTitle)")
                    .accessibilityValue(liked ? Text("Liked") : Text(""))
                }
                if index < tracks.count - 1 { Divider().padding(.leading, 80) }
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func downloadAction(_ track: LibraryTrack, record: OfflineDownload?) -> some View {
        if let record, record.state == .ready {
            Button("Remove offline copy", systemImage: "trash", role: .destructive) {
                do { try downloads.delete(record.id); downloadMessage = "Offline copy removed." }
                catch { downloadMessage = "Could not remove this offline copy." }
            }
        } else if let record, record.pending {
            Button("Cancel offline download", systemImage: "xmark.circle") { downloads.cancel(record.id) }
        } else {
            Button(record == nil ? "Download for offline playback" : "Retry offline download", systemImage: "arrow.down.circle") {
                do { try downloads.enqueue(track); downloadMessage = "Offline download requested." }
                catch { downloadMessage = "Could not start this download." }
            }
        }
    }
}
